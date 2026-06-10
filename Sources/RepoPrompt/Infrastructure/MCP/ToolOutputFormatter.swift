import Foundation
import MCP

extension Value {
    /// Decode this Value into a Decodable type by going through JSON.
    func decode<T: Decodable>(_ type: T.Type) -> T? {
        do {
            let data = try JSONEncoder().encode(self)
            let decoder = JSONDecoder()
            // CodingKeys are explicitly set to snake_case in our DTOs; default strategy is fine.
            return try decoder.decode(T.self, from: data)
        } catch {
            return nil
        }
    }
}

enum ToolOutputFormatter {
    static func statusIcon(success: Bool?, warning: Bool = false) -> String {
        if let success {
            return success ? "✅" : (warning ? "⚠️" : "❌")
        }
        return warning ? "⚠️" : "✅"
    }

    static func bracketedModeList(chat: Bool, plan: Bool, review: Bool) -> String {
        var items: [String] = []
        if chat { items.append("Chat") }
        if plan { items.append("Plan") }
        if review { items.append("Review") }
        return "[\(items.joined(separator: ", "))]"
    }

    private enum WorktreeScopeOperation {
        case codeStructure
        case fileTree
        case search
        case readFile
        case workspaceContext
    }

    private static func worktreeScopeLines(
        _ scope: ToolResultDTOs.WorktreeScopeDTO?,
        operation: WorktreeScopeOperation
    ) -> [String] {
        guard let scope, !scope.rootMappings.isEmpty else { return [] }
        let action = switch operation {
        case .codeStructure:
            "codemap scans use"
        case .fileTree:
            "filesystem reads use"
        case .search:
            "filesystem searches use"
        case .readFile:
            "filesystem reads use"
        case .workspaceContext:
            "filesystem-derived sections use"
        }

        var lines: [String] = []
        lines.append("- **Scope**: session-bound worktree. Displayed paths use logical/canonical roots; \(action) the effective worktree roots below.")
        lines.append("- **Root remapping**:")
        for mapping in scope.rootMappings {
            var details = ["worktree `\(mapping.worktreeID)`"]
            if let worktreeName = nonEmpty(mapping.worktreeName) {
                details.append("name `\(worktreeName)`")
            }
            if let branch = nonEmpty(mapping.branch) {
                details.append("branch `\(branch)`")
            }
            if let label = nonEmpty(mapping.label) {
                details.append("label `\(label)`")
            }
            lines.append("  - `\(mapping.logicalRootName)` `\(mapping.logicalRootPath)` → `\(mapping.effectiveRootName)` `\(mapping.effectiveRootPath)` (\(details.joined(separator: ", ")))")
        }
        return lines
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Search

    static func searchResults(dto: ToolResultDTOs.SearchResultDTO) -> String {
        if let error = dto.errorMessage, !error.isEmpty {
            return searchErrorResults(dto: dto, error: error)
        }
        var lines: [String] = []
        lines.reserveCapacity(16 + dto.perFileCounts.count + dto.pathMatchLines.count + dto.contentMatchGroups.count * 6)
        let hasMatches = (dto.totalMatches > 0) || (dto.pathMatches > 0)
        lines.append("## Search Results \(statusIcon(success: hasMatches))")
        if dto.matchedFiles != nil || dto.searchedFiles != nil {
            let matchingFiles = dto.matchedFiles ?? dto.totalFiles
            var summary = "- **Total matches**: \(dto.totalMatches) across \(matchingFiles) matching file\(matchingFiles == 1 ? "" : "s")"
            if let searchedFiles = dto.searchedFiles {
                summary += " (searched \(searchedFiles) file\(searchedFiles == 1 ? "" : "s"))"
            }
            lines.append(summary)
        } else {
            lines.append("- **Total matches**: \(dto.totalMatches) across \(dto.totalFiles) file\(dto.totalFiles == 1 ? "" : "s")")
        }
        lines.append("- **Content matches**: \(dto.contentMatches) • **Path matches**: \(dto.pathMatches)")
        lines.append("- **Status**: \(dto.limitHit ? "Partial (limit reached)" : "Complete (limit not reached)")")
        if let warning = dto.warning, !warning.isEmpty {
            lines.append("- **Warning**: \(warning)")
        }
        lines.append(contentsOf: worktreeScopeLines(dto.worktreeScope, operation: .search))

        let perFileTotals = dto.perFileTotals ?? dto.perFileCounts
        if !perFileTotals.isEmpty {
            let sortedTotals = perFileTotals.sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.path < rhs.path
            }

            func basename(_ path: String) -> String {
                path.split(separator: "/").last.map(String.init) ?? path
            }

            var nameCounts: [String: Int] = [:]
            nameCounts.reserveCapacity(sortedTotals.count)
            for entry in sortedTotals {
                let name = basename(entry.path)
                nameCounts[name, default: 0] += 1
            }
            let duplicateNames = Set(nameCounts.compactMap { name, count in
                count > 1 ? name : nil
            })
            let topCount = min(3, sortedTotals.count)
            let topEntries = sortedTotals.prefix(topCount)
            let display = topEntries.map { entry -> String in
                let name = basename(entry.path)
                let shown = duplicateNames.contains(name) ? entry.path : name
                return "\(shown) (\(entry.count))"
            }
            let extra = sortedTotals.count - topCount
            var line = "- **Top files**: \(display.joined(separator: ", "))"
            if extra > 0 {
                line += " (+\(extra) more)"
            }
            lines.append(line)
        }

        if dto.sizeLimitHit == true {
            var omittedParts: [String] = []
            if let content = dto.omittedContentMatches, content > 0 {
                omittedParts.append("\(content) content")
            }
            if let path = dto.omittedPathMatches, path > 0 {
                omittedParts.append("\(path) path")
            }
            let detail = omittedParts.isEmpty ? "" : " (" + omittedParts.joined(separator: ", ") + ")"
            if let total = dto.omittedTotal, total > 0 {
                lines.append("- **Omitted**: \(total) results trimmed by response size cap\(detail)")
            } else {
                lines.append("- **Omitted**: Results trimmed by response size cap\(detail)")
            }
        }

        lines.append(contentsOf: searchMatchesTree(dto: dto))

        // Show suggestion if present (e.g., when path filter yields no results)
        if let suggestion = dto.suggestion, !suggestion.isEmpty {
            lines.append("")
            lines.append("### Suggestion")
            lines.append(suggestion)
        }

        return lines.joined(separator: "\n")
    }

    private static func searchErrorResults(dto: ToolResultDTOs.SearchResultDTO, error: String) -> String {
        var lines: [String] = []
        let isBackpressure = dto.errorCode == "search_backpressure" && dto.retryable == true
        let isWorktreeUnavailable = dto.errorCode == "worktree_scope_unavailable" && dto.retryable == true
        lines.append((isBackpressure || isWorktreeUnavailable) ? "## Search Results ⚠️" : "## Search Results ❌")
        if isBackpressure {
            lines.append("- **Status**: Temporarily busy")
        } else if isWorktreeUnavailable {
            lines.append("- **Status**: Worktree unavailable")
        }
        lines.append("- **Error**: \(error)")
        if let errorCode = dto.errorCode, !errorCode.isEmpty {
            lines.append("- **Code**: \(errorCode)")
        }
        if dto.retryable == true {
            lines.append("- **Retryable**: yes")
        }
        if let retryAfterMilliseconds = dto.retryAfterMilliseconds {
            lines.append("- **Retry after**: \(retryAfterMilliseconds) ms")
        }
        if let warning = dto.warning, !warning.isEmpty {
            lines.append("- **Warning**: \(warning)")
        }
        lines.append(contentsOf: worktreeScopeLines(dto.worktreeScope, operation: .search))
        if let suggestion = dto.suggestion, !suggestion.isEmpty {
            lines.append("- **Suggestion**: \(suggestion)")
        }
        return lines.joined(separator: "\n")
    }

    private struct SearchTreeEntry {
        let path: String
        let hasPathMatch: Bool
        let totalContentMatches: Int
        let includedContentMatches: Int
        let omittedContentMatches: Int
        let contentGroup: ToolResultDTOs.SearchResultDTO.ContentMatchGroup?
    }

    private static func searchMatchesTree(dto: ToolResultDTOs.SearchResultDTO) -> [String] {
        let pathMatchSet = Set(dto.pathMatchLines)

        var includedLookup: [String: Int] = [:]
        includedLookup.reserveCapacity(dto.perFileCounts.count)
        for entry in dto.perFileCounts {
            includedLookup[entry.path, default: 0] += entry.count
        }

        let totals = dto.perFileTotals ?? []
        var totalsLookup: [String: Int] = [:]
        totalsLookup.reserveCapacity(totals.count)
        for entry in totals {
            totalsLookup[entry.path, default: 0] += entry.count
        }

        var groupsLookup: [String: ToolResultDTOs.SearchResultDTO.ContentMatchGroup] = [:]
        groupsLookup.reserveCapacity(dto.contentMatchGroups.count)
        for group in dto.contentMatchGroups {
            if let existing = groupsLookup[group.path] {
                var mergedLines = existing.lines
                mergedLines.append(contentsOf: group.lines)
                mergedLines.sort {
                    if $0.lineNumber != $1.lineNumber { return $0.lineNumber < $1.lineNumber }
                    return $0.lineText < $1.lineText
                }
                groupsLookup[group.path] = ToolResultDTOs.SearchResultDTO.ContentMatchGroup(path: group.path, lines: mergedLines)
            } else {
                groupsLookup[group.path] = group
            }
        }

        var contentPaths = Set<String>()
        for entry in dto.perFileCounts {
            contentPaths.insert(entry.path)
        }
        for group in dto.contentMatchGroups {
            contentPaths.insert(group.path)
        }

        let candidatePaths = contentPaths.union(pathMatchSet)
        var folderPrefixes = Set<String>()
        for path in candidatePaths {
            let parts = path.split(separator: "/").map(String.init)
            guard parts.count > 1 else { continue }
            var current = ""
            for index in 0 ..< (parts.count - 1) {
                current = current.isEmpty ? parts[index] : "\(current)/\(parts[index])"
                folderPrefixes.insert(current)
            }
        }

        let folderMatchSet = pathMatchSet.intersection(folderPrefixes)
        let leafPathMatchSet = pathMatchSet.subtracting(folderMatchSet)
        let includedPaths = contentPaths.union(leafPathMatchSet)

        guard !includedPaths.isEmpty else { return [] }

        let entries: [SearchTreeEntry] = includedPaths.map { path in
            let group = groupsLookup[path]
            let included = includedLookup[path] ?? group?.lines.count ?? 0
            let total = totalsLookup[path] ?? included
            let omitted = max(0, total - included)
            return SearchTreeEntry(
                path: path,
                hasPathMatch: pathMatchSet.contains(path),
                totalContentMatches: total,
                includedContentMatches: included,
                omittedContentMatches: omitted,
                contentGroup: group
            )
        }

        let (commonPrefix, roots) = buildPathTree(items: entries, path: { $0.path })
        var lines: [String] = []
        lines.append("")
        lines.append("### Matches")
        if !commonPrefix.isEmpty {
            let suffix = folderMatchSet.contains(commonPrefix) ? " \u{2022} path match" : ""
            lines.append("\(commonPrefix)/\(suffix)")
        }
        lines.append(contentsOf: renderPathTree(
            nodes: roots,
            basePath: commonPrefix,
            compactUnaryFolders: true,
            folderSuffix: { fullPath in
                folderMatchSet.contains(fullPath) ? " \u{2022} path match" : nil
            },
            fileLine: { entry, name in
                if entry.totalContentMatches > 0 {
                    let label = entry.totalContentMatches == 1 ? "match" : "matches"
                    let showing = entry.omittedContentMatches > 0
                        ? "(showing first \(entry.includedContentMatches))"
                        : "(showing all)"
                    let suffix = entry.hasPathMatch ? " \u{2022} path match" : ""
                    return "\(name) \u{2014} \(entry.totalContentMatches) \(label) \(showing)\(suffix)"
                }
                return "\(name) \u{2014} path match"
            },
            fileChildren: { entry, childPrefix in
                guard let group = entry.contentGroup else { return [] }
                let snippetLines = matchSnippetLines(for: group, adjacency: 2)
                var output: [String] = []
                output.reserveCapacity(snippetLines.count + (entry.omittedContentMatches > 0 ? 1 : 0))
                let baseIndent = "    " + childPrefix
                for line in snippetLines {
                    if line.isEmpty {
                        output.append(baseIndent)
                    } else {
                        output.append(baseIndent + "    " + line)
                    }
                }
                if entry.omittedContentMatches > 0 {
                    output.append(baseIndent + "    [\(entry.omittedContentMatches) more matches in this file - use higher max_results to see all]")
                }
                return output
            }
        ))
        return lines
    }

    // MARK: - Prompt State

    static func promptState(prompt: String, selectedPaths: [String], fileSlices: [ToolResultDTOs.FileSliceDTO]? = nil) -> String {
        var out: [String] = []
        out.reserveCapacity(8 + selectedPaths.count * 2)
        out.append("## Prompt State \(statusIcon(success: true))")
        out.append("- **Selected files**: \(selectedPaths.count)")
        let lines = prompt.isEmpty ? 0 : prompt.components(separatedBy: "\n").count
        out.append("- **Prompt lines**: \(lines)")
        if !prompt.isEmpty {
            out.append("")
            out.append("### Prompt")
            out.append("```text\n\(prompt)\n```")
        }
        if !selectedPaths.isEmpty {
            out.append("")
            out.append("### Selection")
            // Build lookup for slices
            let sliceLookup = selectionRangeLookup(from: fileSlices)
            for path in selectedPaths {
                if let ranges = sliceLookup[path], !ranges.isEmpty {
                    let formatted = formatRanges(ranges)
                    out.append("• `\(path)` — lines \(formatted)")
                } else {
                    out.append("• `\(path)`")
                }
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - File Tree

    static func fileTreeSummary(
        rootsCount: Int,
        usesLegend: Bool,
        tree: String,
        note: String?,
        worktreeScope: ToolResultDTOs.WorktreeScopeDTO? = nil,
        includeWorktreeScope: Bool = true
    ) -> String {
        var out: [String] = []
        let treeLines = tree.split(separator: "\n", omittingEmptySubsequences: false).count
        out.reserveCapacity(8 + treeLines)
        out.append("## File Tree \(statusIcon(success: true))")
        out.append("- **Roots**: \(rootsCount)")
        out.append("- **Selected markers**: \(usesLegend ? "yes" : "no")")
        out.append("- **Note**: '...' indicates truncated content")
        if let note, !note.isEmpty {
            out.append("- **Config**: \(note)")
        }
        if includeWorktreeScope {
            out.append(contentsOf: worktreeScopeLines(worktreeScope, operation: .fileTree))
        }
        if usesLegend {
            out.append("\n(* denotes selected files)\n(+ denotes code-map available)")
        }
        if !tree.isEmpty { out.append("\n" + tree) }
        return out.joined(separator: "\n")
    }

    // MARK: - Selected Code Structure

    static func selectedCodeStructure(fileCount: Int, content: String) -> String {
        var out: [String] = []
        out.reserveCapacity(6 + (content.isEmpty ? 0 : content.split(separator: "\n").count + 4))
        out.append("## Selected Code Structure \(statusIcon(success: fileCount > 0))")
        out.append("- **Files**: \(fileCount)")
        if !content.isEmpty {
            out.append("")
            out.append("```text\n\(content)\n```")
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Read File

    static func readFile(
        path: String,
        first: Int,
        last: Int,
        total: Int,
        language: String,
        message: String?,
        content: String,
        worktreeScope: ToolResultDTOs.WorktreeScopeDTO? = nil
    ) -> String {
        var out: [String] = []
        out.append("## File Read \(statusIcon(success: true))")
        out.append("- **Path**: `\(path)`")
        out.append("- **Lines**: \(first)–\(last) of \(total)")
        if let m = message, !m.isEmpty { out.append("- **Note**: \(m)") }
        out.append(contentsOf: worktreeScopeLines(worktreeScope, operation: .readFile))
        out.append("")
        out.append("```\(language)\n\(content)\n```")
        return out.joined(separator: "\n")
    }

    // MARK: - Token Stats

    static func tokenStats(
        total: Int,
        files: Int,
        filesContent: Int? = nil,
        codemaps: Int? = nil,
        prompt: Int? = nil,
        fileTree: Int? = nil,
        meta: Int? = nil,
        git: Int? = nil,
        other: Int? = nil
    ) -> String {
        var out: [String] = []
        out.append("## Token Statistics \(statusIcon(success: true))")
        out.append("- **Total tokens**: \(total)")
        // Show files and codemaps separately if either is present
        let hasBreakdown = (filesContent != nil && filesContent! > 0) || (codemaps != nil && codemaps! > 0)
        if hasBreakdown {
            if let filesContent, filesContent > 0 {
                out.append("- Files tokens: \(filesContent)")
            }
            if let codemaps, codemaps > 0 {
                out.append("- Codemaps tokens: \(codemaps)")
            }
        } else {
            out.append("- Files tokens: \(files)")
        }
        if let prompt, prompt > 0 {
            out.append("- Prompt tokens: \(prompt)")
        }
        if let fileTree, fileTree > 0 {
            out.append("- File tree tokens: \(fileTree)")
        }
        if let meta, meta > 0 {
            out.append("- Stored prompt tokens: \(meta)")
        }
        if let git, git > 0 {
            out.append("- Git tokens: \(git)")
        }
        if let other, other > 0 {
            out.append("- Other tokens: \(other)")
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Apply Edits

    static func applyEdits(editsRequested: Int?, editsApplied: Int?, linesChanged: Int?, chunks: Int?, diff: String?) -> String {
        let applied = editsApplied ?? 0
        let requested = editsRequested ?? 0
        // Status icon rules:
        // - success: all requested edits applied
        // - warning: some applied, but not all (partial)
        // - failure: none applied
        let isSuccess: Bool = {
            if let editsRequested {
                return editsRequested > 0 ? (applied == requested) : (editsApplied ?? 0) > 0
            }
            if let editsApplied {
                return editsApplied > 0
            }
            return (linesChanged ?? 0) > 0 || (chunks ?? 0) > 0 || diff?.isEmpty == false
        }()
        let isWarning = editsRequested != nil && editsApplied != nil && requested > 0 && applied > 0 && applied < requested
        let isFailure = editsRequested != nil && editsApplied != nil && requested > 0 && applied == 0
        var out: [String] = []
        out.reserveCapacity(diff?.isEmpty == false ? 12 : 8)
        out.append("## Apply Edits \(statusIcon(success: isFailure ? false : (isWarning ? nil : isSuccess), warning: isWarning))")
        if let requested = editsRequested { out.append("- **Requested**: \(requested)") }
        if let applied = editsApplied { out.append("- **Applied**: \(applied)") }
        if let l = linesChanged { out.append("- **Lines changed**: \(l)") }
        if let c = chunks { out.append("- **Chunks**: \(c)") }
        if let d = diff, !d.isEmpty {
            out.append("")
            out.append("### Unified Diff")
            out.append("```diff\n\(d)\n```")
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Chat Send

    static func chatSend(chatId: String?, mode: String?, response: String?, diffs: [(path: String, patch: String)]) -> String {
        var out: [String] = []
        out.reserveCapacity(6 + diffs.count * 2)
        out.append("## Chat Send \(statusIcon(success: true))")
        if let id = chatId, let m = mode { out.append("- **Chat**: `\(id)` | **Mode**: \(m)") }
        if let resp = response, !resp.isEmpty {
            out.append("")
            out.append("### Response")
            out.append(resp)
        }
        if !diffs.isEmpty {
            out.append("")
            out.append("### Patches")
            out.append("**Note:** The diffs shown below have already been applied to the files on disk.")
            out.append("")
            for d in diffs {
                out.append("Patch for `\(d.path)`:")
                out.append("\n```diff\n\(d.patch)\n```")
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Ask Oracle

    static func askOracle(chatId: String?, mode: String?, response: String?, diffs: [(path: String, patch: String)]) -> String {
        var out: [String] = []
        out.reserveCapacity(6 + diffs.count * 2)
        out.append("## Ask Oracle \(statusIcon(success: true))")
        if let id = chatId, let m = mode { out.append("- **Chat**: `\(id)` | **Mode**: \(m)") }
        if let resp = response, !resp.isEmpty {
            out.append("")
            out.append("### Response")
            out.append(resp)
        }
        if !diffs.isEmpty {
            out.append("")
            out.append("### Patches")
            out.append("**Note:** The diffs shown below have already been applied to the files on disk.")
            out.append("")
            for d in diffs {
                out.append("Patch for `\(d.path)`:")
                out.append("\n```diff\n\(d.patch)\n```")
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Selected Files Content

    static func selectedFiles(count: Int, blocks: [String]) -> String {
        var out: [String] = []
        out.reserveCapacity(6 + blocks.count)
        out.append("## Selected Files \(statusIcon(success: count > 0))")
        out.append("- **Files**: \(count)")
        if !blocks.isEmpty { out.append("")
            out.append(blocks.joined(separator: "\n\n"))
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Chat Log

    // MARK: - Models

    static func models(_ entries: [(id: String, name: String, desc: String?)]) -> String {
        var out: [String] = []
        out.reserveCapacity(6 + entries.count)
        out.append("## Models \(statusIcon(success: !entries.isEmpty))")
        out.append("- **Count**: \(entries.count)")
        if !entries.isEmpty {
            out.append("")
            for e in entries {
                let d = (e.desc?.isEmpty == false) ? " — \(e.desc!)" : ""
                out.append("- `\(e.id)`: \(e.name)\(d)")
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Chats List

    static func chatsList(_ entries: [(id: String, name: String, last: String, count: Int, files: Int, current: Bool)]) -> String {
        var out: [String] = []
        out.reserveCapacity(6 + entries.count)
        out.append("## Chats \(statusIcon(success: true))")
        out.append("- **Count**: \(entries.count)")
        if !entries.isEmpty {
            out.append("")
            for c in entries {
                let star = c.current ? " ⭐" : ""
                out.append("- `\(c.id)`: \(c.name) — messages=\(c.count), files=\(c.files), last=\(c.last)\(star)")
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Generic Object Summary

    static func genericSummary(title: String = "Result", value: Value) -> String {
        var out: [String] = []
        out.append("## \(title) \(statusIcon(success: true))")
        switch value {
        case let .string(s):
            out.append(s)
        case let .array(arr):
            out.append("- **Items**: \(arr.count)")
        case let .object(obj):
            out.append("- **Fields**: \(obj.keys.count)")
            let scalarKeys = obj.keys.sorted().filter { key in
                if case .string = obj[key]! { return true }
                if case .int = obj[key]! { return true }
                if case .bool = obj[key]! { return true }
                return false
            }
            if !scalarKeys.isEmpty {
                out.append("")
                out.append("### Summary")
                for k in scalarKeys.prefix(12) {
                    out.append("- **\(k)**: \(obj[k]!.stringValue ?? String(describing: obj[k]!))")
                }
            }
        default:
            break
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Errors

    static func operationFailed(title: String? = nil, issue: String, troubleshooting: [String]? = nil) -> String {
        var out: [String] = []
        out.append("## \(title ?? "Operation Failed") ❌")
        out.append("")
        out.append("**Issue**: \(issue)")
        if let steps = troubleshooting, !steps.isEmpty {
            out.append("")
            out.append("**Troubleshooting Steps**:")
            for (i, s) in steps.enumerated() {
                out.append("\(i + 1). \(s)")
            }
        }
        return out.joined(separator: "\n")
    }
}

enum AppSettingValueFormatter {
    static func summaryForSubtitle(_ value: Any, maxChars: Int = 24) -> String {
        if let preview = decodeLongStringPreview(value) {
            return quotedPreview(preview.preview, length: preview.length, maxChars: maxChars, markdown: false)
        }

        switch value {
        case _ as NSNull:
            return "null"
        case let bool as Bool:
            return bool ? "true" : "false"
        case let number as NSNumber:
            return number.stringValue
        case let string as String:
            return quotedString(string, maxChars: maxChars, markdown: false)
        case let array as [Any]:
            return "[\(array.count) item\(array.count == 1 ? "" : "s")]"
        case let object as [String: Any]:
            return "{\(object.count) field\(object.count == 1 ? "" : "s")}"
        default:
            return String(describing: value)
        }
    }

    static func summaryForMarkdown(_ value: Value, maxChars: Int = 80) -> String {
        if let preview = decodeLongStringPreview(value) {
            return quotedPreview(preview.preview, length: preview.length, maxChars: maxChars, markdown: true)
        }

        switch value {
        case .null:
            return "*null*"
        case let .bool(bool):
            return "`\(bool ? "true" : "false")`"
        case let .int(int):
            return "`\(int)`"
        case let .double(double):
            return "`\(double)`"
        case let .string(string):
            return quotedString(string, maxChars: maxChars, markdown: true)
        case let .array(array):
            return "`[\(array.count) item\(array.count == 1 ? "" : "s")]`"
        case let .object(object):
            return "`{\(object.count) field\(object.count == 1 ? "" : "s")}`"
        default:
            return "`\(String(describing: value))`"
        }
    }

    static func sideEffectLabel(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        switch raw {
        case "applies_immediately":
            return "applies immediately to all windows"
        case "requires_window_reopen":
            return "takes effect the next time a window opens"
        case "requires_app_relaunch":
            return "takes effect after relaunching RepoPrompt"
        case "refreshes_tool_list":
            return "refreshes the MCP tool list"
        case "noop":
            return nil
        default:
            return raw
        }
    }

    private static func decodeLongStringPreview(_ value: Value) -> (preview: String, length: Int?)? {
        guard let object = value.objectValue,
              let preview = object["value_preview"]?.stringValue
        else { return nil }
        let length = object["value_length"]?.intValue
            ?? object["value_length"]?.stringValue.flatMap(Int.init)
        return (preview, length)
    }

    private static func decodeLongStringPreview(_ value: Any) -> (preview: String, length: Int?)? {
        guard let object = value as? [String: Any],
              let preview = object["value_preview"] as? String
        else { return nil }
        let length: Int? = if let int = object["value_length"] as? Int {
            int
        } else if let number = object["value_length"] as? NSNumber {
            number.intValue
        } else if let string = object["value_length"] as? String {
            Int(string)
        } else {
            nil
        }
        return (preview, length)
    }

    private static func quotedPreview(_ preview: String, length: Int?, maxChars: Int, markdown: Bool) -> String {
        let sanitized = sanitize(preview)
        let coreLimit = max(1, maxChars)
        let displayedCore: String
        let visibleCount: Int
        if sanitized.count > coreLimit {
            let prefixLength = max(1, coreLimit - 1)
            displayedCore = "\(sanitized.prefix(prefixLength))…"
            visibleCount = prefixLength
        } else {
            displayedCore = sanitized
            visibleCount = sanitized.count
        }
        let tail = if let length, length > visibleCount {
            " (…+\(length - visibleCount) chars)"
        } else {
            ""
        }
        let literal = "\"\(escapeQuoted(displayedCore))\""
        return markdown ? "\(markdownCodeSpan(literal))\(tail)" : "\(literal)\(tail)"
    }

    private static func quotedString(_ string: String, maxChars: Int, markdown: Bool) -> String {
        let sanitized = sanitize(string)
        let coreLimit = max(1, maxChars)
        let displayedCore: String
        let tail: String
        if sanitized.count > coreLimit {
            let prefixLength = max(1, coreLimit - 1)
            displayedCore = "\(sanitized.prefix(prefixLength))…"
            tail = " (…+\(sanitized.count - prefixLength) chars)"
        } else {
            displayedCore = sanitized
            tail = ""
        }
        let literal = "\"\(escapeQuoted(displayedCore))\""
        return markdown ? "\(markdownCodeSpan(literal))\(tail)" : "\(literal)\(tail)"
    }

    private static func sanitize(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }

    private static func escapeQuoted(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func markdownCodeSpan(_ content: String) -> String {
        var longestRun = 0
        var currentRun = 0
        for character in content {
            if character == "`" {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }
        let delimiter = String(repeating: "`", count: longestRun + 1)
        let needsPadding = content.first == "`" || content.last == "`"
        let padding = needsPadding ? " " : ""
        return "\(delimiter)\(padding)\(content)\(padding)\(delimiter)"
    }
}

extension ToolOutputFormatter {
    /// Encode a `Value` as compact JSON (no markdown fences).
    static func rawJSONString(_ value: Value) -> String {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(value)
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return "{}"
        }
    }

    private static func wantsRawJSON(args: [String: Value]) -> Bool {
        guard let v = args["_rawJSON"] else { return false }
        switch v {
        case let .bool(b): return b
        case let .int(i): return i != 0
        case let .double(d): return d != 0
        case let .string(s):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["1", "true", "yes", "y", "on"].contains(t)
        default:
            return false
        }
    }

    // Run-ID note removed — routing is handled automatically by the MCP connection layer

    /// Central router: build content blocks for any tool based on name + result.
    static func buildContentBlocks(
        toolName: String,
        args: [String: Value],
        result: Value,
        emitResources: Bool
    ) -> [MCP.Tool.Content] {
        // Raw JSON mode: bypass all markdown/text formatting.
        if wantsRawJSON(args: args) {
            return [.text(rawJSONString(result))]
        }

        switch toolName {
        case "workspace_context":
            return formatPromptState(value: result)
        case "manage_selection":
            return formatManageSelection(args: args, value: result)
        case "prompt":
            return formatPrompt(value: result)
        case "chats":
            let action = args["action"]?.stringValue?.lowercased()
                ?? args["op"]?.stringValue?.lowercased()
                ?? "list"
            if action == "log" {
                return formatChatLog(value: result, emitResources: emitResources)
            } else {
                return formatChatList(value: result)
            }
        case "read_file":
            return formatReadFile(args: args, value: result)
        case "apply_edits":
            return formatApplyEdits(value: result, emitResources: emitResources)
        case "ask_oracle":
            return formatAskOracle(args: args, value: result, emitResources: emitResources)
        case "oracle_send":
            return formatChatSend(args: args, value: result, emitResources: emitResources)
        case "oracle_utils":
            let op = args["op"]?.stringValue?.lowercased() ?? "models"
            if op == "models" {
                return formatListModels(value: result)
            } else if op == "sessions" {
                return formatChatList(value: result)
            } else {
                if result.objectValue?["messages"]?.arrayValue != nil,
                   result.objectValue?["chat_id"]?.stringValue != nil,
                   result.objectValue?["action"] == nil
                {
                    return formatOracleChatLog(args: args, value: result, emitResources: emitResources)
                }
                return formatChatLog(value: result, emitResources: emitResources)
            }
        case "oracle_chat_log":
            return formatOracleChatLog(args: args, value: result, emitResources: emitResources)
        case "file_search":
            return formatSearch(value: result)
        case "get_file_tree":
            return formatFileTree(value: result)
        case "get_code_structure":
            return formatCodeStructure(value: result)
        case "list_models":
            return formatListModels(value: result)
        case "file_actions":
            return formatFileAction(value: result)
        case "bind_context":
            return formatBindContext(args: args, value: result)
        case "manage_workspaces":
            return formatManageWorkspaces(args: args, value: result)
        case "git":
            return formatGit(args: args, value: result, emitResources: emitResources)
        case "manage_worktree":
            return formatManageWorktree(args: args, value: result)
        case "context_builder":
            return formatDiscoverContext(value: result)
        case "app_settings":
            return formatAppSettings(args: args, value: result)
        case "agent_explore":
            return formatAgentExplore(args: args, value: result)
        case "agent_run":
            return formatAgentRun(args: args, value: result)
        case "agent_manage":
            return formatAgentManage(args: args, value: result)
        default:
            return formatGeneric(value: result)
        }
    }

    // MARK: - App Settings

    static func formatAppSettings(args: [String: Value], value: Value) -> [MCP.Tool.Content] {
        guard let object = value.objectValue else {
            return formatGeneric(value: value)
        }

        let op = normalizedAppSettingsOp(object["op"]?.stringValue)
            ?? normalizedAppSettingsOp(args["op"]?.stringValue)
        let status = object["status"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isFailure = object["isError"]?.boolValue == true
            || status.map { ["error", "failed", "failure"].contains($0) } == true
            || trimmedAppSettingsString(object["error"]?.stringValue) != nil
        if isFailure {
            return [.text(formatAppSettingsFailure(args: args, object: object, op: op))]
        }

        guard let op, ["list", "get", "set", "options"].contains(op) else {
            return formatGeneric(value: value)
        }

        switch op {
        case "list":
            return [.text(formatAppSettingsList(args: args, object: object))]
        case "get":
            return [.text(formatAppSettingsGet(object: object))]
        case "set":
            return [.text(formatAppSettingsSet(args: args, object: object))]
        case "options":
            return [.text(formatAppSettingsOptions(args: args, object: object))]
        default:
            return formatGeneric(value: value)
        }
    }

    private static func formatAppSettingsList(args: [String: Value], object: [String: Value]) -> String {
        let settings = object["settings"]?.arrayValue?.compactMap(\.objectValue) ?? []
        let renderedCount = settings.count
        let declaredCount = object["count"]?.intValue ?? renderedCount
        let requestedGroup = trimmedAppSettingsString(args["group"]?.stringValue)
        let groups = object["groups"]?.arrayValue?.compactMap { trimmedAppSettingsString($0.stringValue) } ?? []
        let detailed = appSettingsDetailedFlag(args: args, object: object)

        var lines: [String] = []
        lines.append("## App Settings ✅")
        if let requestedGroup {
            lines.append("- **Scope**: group `\(requestedGroup)` • \(declaredCount) setting\(declaredCount == 1 ? "" : "s")")
        } else {
            lines.append("- **Scope**: all groups • \(declaredCount) setting\(declaredCount == 1 ? "" : "s")")
        }
        if !groups.isEmpty {
            lines.append("- **Groups**: \(groups.joined(separator: ", "))")
        }

        guard !settings.isEmpty else {
            return lines.joined(separator: "\n")
        }

        let grouped = Dictionary(grouping: settings) { setting in
            trimmedAppSettingsString(setting["group"]?.stringValue) ?? "other"
        }
        var groupOrder = groups.filter { grouped[$0] != nil }
        let missingGroups = grouped.keys.filter { !groupOrder.contains($0) }.sorted()
        groupOrder.append(contentsOf: missingGroups)

        let maxGroups = 6
        let maxSettingsPerGroup = 12
        let maxSettingsTotal = 40
        let visibleGroups = Array(groupOrder.prefix(maxGroups))
        let foldedGroups = Array(groupOrder.dropFirst(maxGroups))
        var renderedSettings = 0
        var aliasesDetected = false
        var groupOmissionLines = 0
        var groupOmittedTotal = 0

        func appendGroup(_ title: String, settings groupSettings: [[String: Value]], folded: Bool = false) {
            guard renderedSettings < maxSettingsTotal, !groupSettings.isEmpty else { return }
            lines.append("")
            lines.append("### \(folded ? "Other" : title)")
            let sortedSettings = groupSettings.sorted { lhs, rhs in
                (lhs["key"]?.stringValue ?? "") < (rhs["key"]?.stringValue ?? "")
            }
            let allowedInGroup = min(maxSettingsPerGroup, maxSettingsTotal - renderedSettings)
            let visibleSettings = sortedSettings.prefix(allowedInGroup)
            for setting in visibleSettings {
                if detailed {
                    if setting["allowed_aliases"] != nil { aliasesDetected = true }
                    lines.append(appSettingsCatalogLine(setting))
                    if let currentLine = appSettingsCurrentValueLine(setting) {
                        lines.append(currentLine)
                    }
                    if let format = trimmedAppSettingsString(setting["value_format"]?.stringValue) {
                        lines.append("  - *format: \(truncateAppSettings(format, limit: 120))*")
                    }
                } else {
                    lines.append(appSettingsCompactCatalogLine(setting))
                }
                renderedSettings += 1
            }
            let omittedInGroup = max(0, sortedSettings.count - visibleSettings.count)
            if omittedInGroup > 0, renderedSettings < maxSettingsTotal {
                lines.append("- …and \(omittedInGroup) more settings in `\(title)`.")
                groupOmissionLines += 1
                groupOmittedTotal += omittedInGroup
            }
        }

        for group in visibleGroups {
            appendGroup(group, settings: grouped[group] ?? [])
        }
        if renderedSettings < maxSettingsTotal, !foldedGroups.isEmpty {
            let foldedSettings = foldedGroups.flatMap { grouped[$0] ?? [] }
            appendGroup("Other", settings: foldedSettings, folded: true)
        }

        let omittedTotal = max(0, max(declaredCount, renderedCount) - renderedSettings)
        if omittedTotal > 0, !(groupOmissionLines == 1 && groupOmittedTotal == omittedTotal) {
            let hint = requestedGroup == nil ? "call with group=… to narrow" : "call with a narrower group or key to inspect details"
            lines.append("")
            lines.append("…and \(omittedTotal) more settings (\(hint)).")
        }
        if detailed, aliasesDetected || settings.contains(where: { $0["allowed_aliases"] != nil }) {
            lines.append("")
            lines.append("Aliases accepted for enum writes.")
        }
        return lines.joined(separator: "\n")
    }

    private static func appSettingsCompactCatalogLine(_ setting: [String: Value]) -> String {
        let key = trimmedAppSettingsString(setting["key"]?.stringValue) ?? "(unknown)"
        let type = appSettingsDisplayType(setting["type"]?.stringValue)
        var line = "- `\(key)` (\(type))"
        if let value = appSettingsCurrentValue(setting) {
            line += " = \(AppSettingValueFormatter.summaryForMarkdown(value, maxChars: 80))"
        }
        return line
    }

    private static func appSettingsCatalogLine(_ setting: [String: Value]) -> String {
        let key = trimmedAppSettingsString(setting["key"]?.stringValue) ?? "(unknown)"
        let type = appSettingsDisplayType(setting["type"]?.stringValue)
        let label = trimmedAppSettingsString(setting["label"]?.stringValue)
        let allowed = setting["allowed_values"]?.arrayValue?.compactMap { trimmedAppSettingsString($0.stringValue) } ?? []
        let typeSuffix = allowed.isEmpty ? type : "\(type), enum"
        var line = "- `\(key)`"
        if let label {
            line += " — **\(label)**"
        }
        line += " (\(typeSuffix))"
        if !allowed.isEmpty {
            line += " — \(appSettingsAllowedValuesSummary(allowed))"
        } else if let description = appSettingsUsefulDescription(setting["description"]?.stringValue, key: key) {
            line += " — \(description)"
        }
        if setting["options_available"]?.boolValue == true {
            line += " Options: call `app_settings op=options key=\(key)`."
        }
        return line
    }

    private static func appSettingsCurrentValue(_ setting: [String: Value]) -> Value? {
        if let explicitValue = setting["value"] {
            return explicitValue
        }
        if setting["value_preview"] != nil {
            var previewObject: [String: Value] = [:]
            if let preview = setting["value_preview"] { previewObject["value_preview"] = preview }
            if let length = setting["value_length"] { previewObject["value_length"] = length }
            return .object(previewObject)
        }
        return nil
    }

    private static func appSettingsCurrentValueLine(_ setting: [String: Value]) -> String? {
        guard let value = appSettingsCurrentValue(setting) else {
            if let sideEffect = AppSettingValueFormatter.sideEffectLabel(setting["side_effect"]?.stringValue) {
                return "  - side-effect: \(sideEffect)"
            }
            return nil
        }
        var line = "  - current: \(AppSettingValueFormatter.summaryForMarkdown(value, maxChars: 80))"
        if let sideEffect = AppSettingValueFormatter.sideEffectLabel(setting["side_effect"]?.stringValue) {
            line += " • side-effect: \(sideEffect)"
        }
        return line
    }

    private static func formatAppSettingsGet(object: [String: Value]) -> String {
        let values = object["values"]?.objectValue ?? [:]
        let sortedKeys = values.keys.sorted()
        let count = object["count"]?.intValue ?? sortedKeys.count
        var lines: [String] = []
        lines.append("## App Settings ✅")
        lines.append("- **Operation**: `get` • \(count) value\(count == 1 ? "" : "s")")

        guard !sortedKeys.isEmpty else {
            return lines.joined(separator: "\n")
        }

        lines.append("")
        if sortedKeys.count <= 20 {
            lines.append("| Key | Value |")
            lines.append("| --- | --- |")
            for key in sortedKeys {
                let summary = AppSettingValueFormatter.summaryForMarkdown(values[key] ?? .null, maxChars: 80)
                lines.append("| `\(key)` | \(escapeMarkdownTableCell(summary)) |")
            }
        } else {
            let maxValues = 40
            let visibleKeys = Array(sortedKeys.prefix(maxValues))
            let groupedKeys = Dictionary(grouping: visibleKeys) { key in
                key.split(separator: ".", maxSplits: 1).first.map(String.init) ?? "other"
            }
            for group in groupedKeys.keys.sorted() {
                lines.append("### \(group)")
                for key in (groupedKeys[group] ?? []).sorted() {
                    let summary = AppSettingValueFormatter.summaryForMarkdown(values[key] ?? .null, maxChars: 80)
                    lines.append("- `\(key)`: \(summary)")
                }
                lines.append("")
            }
            if lines.last == "" { lines.removeLast() }
            let omitted = max(0, sortedKeys.count - visibleKeys.count)
            if omitted > 0 {
                lines.append("")
                lines.append("…and \(omitted) more values (call with key=… for a single setting).")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func formatAppSettingsSet(args: [String: Value], object: [String: Value]) -> String {
        let key = trimmedAppSettingsString(object["key"]?.stringValue)
            ?? trimmedAppSettingsString(args["key"]?.stringValue)
        let changed = object["changed"]?.boolValue
        let applied = object["applied"]?.boolValue
        let warning = changed == true && applied == false
        var lines: [String] = []
        lines.append("## App Settings \(warning ? "⚠️" : "✅")")
        if let key {
            lines.append("- **Operation**: `set` • `\(key)`")
        } else {
            lines.append("- **Operation**: `set`")
        }

        if let changed {
            if changed {
                lines.append("- **Changed**: yes")
                if let oldValue = object["old_value"], let newValue = object["new_value"] {
                    lines.append("- **Old → New**: \(AppSettingValueFormatter.summaryForMarkdown(oldValue, maxChars: 80)) → \(AppSettingValueFormatter.summaryForMarkdown(newValue, maxChars: 80))")
                } else if let requestedValue = args["value"] {
                    lines.append("- **New**: \(AppSettingValueFormatter.summaryForMarkdown(requestedValue, maxChars: 80))")
                }
            } else {
                lines.append("- **Changed**: no (value unchanged)")
                if let current = object["new_value"] ?? object["old_value"] ?? args["value"] {
                    lines.append("- **Current**: \(AppSettingValueFormatter.summaryForMarkdown(current, maxChars: 80))")
                }
            }
        } else if let requestedValue = args["value"] {
            lines.append("- **Requested value**: \(AppSettingValueFormatter.summaryForMarkdown(requestedValue, maxChars: 80))")
        }

        if let sideEffect = AppSettingValueFormatter.sideEffectLabel(object["side_effect"]?.stringValue) {
            lines.append("- **Side effect**: \(sideEffect)")
        }
        if changed == true, applied == false {
            lines.append("")
            lines.append("### Warning")
            lines.append("**Warning**: change reported as unapplied.")
        }
        return lines.joined(separator: "\n")
    }

    private static func formatAppSettingsOptions(args: [String: Value], object: [String: Value]) -> String {
        let key = trimmedAppSettingsString(object["key"]?.stringValue)
            ?? trimmedAppSettingsString(args["key"]?.stringValue)
        let source = trimmedAppSettingsString(object["source"]?.stringValue)
        let options = object["options"]?.arrayValue?.compactMap(\.objectValue) ?? []
        let count = object["count"]?.intValue ?? options.count
        let totalCount = object["total_count"]?.intValue ?? count
        let truncated = object["truncated"]?.boolValue == true
        let nullable = object["nullable"]?.boolValue == true
        let hasClearValue = object["clear_value"] != nil
        let exhaustive = object["exhaustive"]?.boolValue
        let filters = object["filters"]?.objectValue ?? [:]
        let notes = object["notes"]?.arrayValue?.compactMap { trimmedAppSettingsString($0.stringValue) } ?? []
        let generatedAt = trimmedAppSettingsString(object["generated_at"]?.stringValue)

        var lines: [String] = []
        lines.append("## App Settings Options ✅")
        if let key {
            lines.append("- **Key**: `\(key)`")
        }
        if let source {
            lines.append("- **Source**: `\(source)`")
        }
        if truncated || totalCount != count {
            lines.append("- **Options**: \(count) of \(totalCount) shown")
        } else {
            lines.append("- **Options**: \(count)")
        }
        if nullable || hasClearValue {
            lines.append("- **Nullable**: yes — clear with `value=null`")
        }
        if exhaustive == false {
            lines.append("- **Exhaustive**: no (custom raw identifiers may still be accepted)")
        }
        if !filters.isEmpty {
            let sortedFilterKeys = filters.keys.sorted()
            let summarized = sortedFilterKeys.compactMap { filterKey -> String? in
                guard let filterValue = filters[filterKey] else { return nil }
                let summary: String = if let string = filterValue.stringValue {
                    "`\(string)`"
                } else {
                    AppSettingValueFormatter.summaryForMarkdown(filterValue, maxChars: 40)
                }
                return "\(filterKey)=\(summary)"
            }
            if !summarized.isEmpty {
                lines.append("- **Filters**: \(summarized.joined(separator: ", "))")
            }
        }
        if let generatedAt {
            lines.append("- **Generated at**: \(generatedAt)")
        }

        let maxRows = 40
        if !options.isEmpty {
            let visibleOptions = Array(options.prefix(maxRows))
            lines.append("")
            lines.append("| Value | Label | Group | Default |")
            lines.append("| --- | --- | --- | --- |")
            for candidate in visibleOptions {
                let valueCell = AppSettingValueFormatter.summaryForMarkdown(candidate["value"] ?? .null, maxChars: 80)
                let labelCell = trimmedAppSettingsString(candidate["label"]?.stringValue) ?? ""
                let groupCell = trimmedAppSettingsString(candidate["group_label"]?.stringValue)
                    ?? trimmedAppSettingsString(candidate["group"]?.stringValue)
                    ?? ""
                let defaultCell = candidate["is_default"]?.boolValue == true ? "yes" : ""
                lines.append("| \(escapeMarkdownTableCell(valueCell)) | \(escapeMarkdownTableCell(labelCell)) | \(escapeMarkdownTableCell(groupCell)) | \(defaultCell) |")
            }
            let omitted = max(0, options.count - visibleOptions.count)
            if omitted > 0 {
                lines.append("")
                lines.append("…and \(omitted) more options in this response. Re-run with `agent=...` or a lower `limit` to narrow.")
            }

            // Detect detailed envelopes heuristically: any visible candidate carrying at least
            // one of description/tags/context_window_tokens/reasoning_effort means the service
            // emitted richer fields and we should surface them below the compact table.
            let detailedCandidates = visibleOptions.filter { appSettingsOptionCarriesDetailedFields($0) }
            if !detailedCandidates.isEmpty {
                lines.append("")
                lines.append("### Details")
                for candidate in detailedCandidates {
                    lines.append("")
                    lines.append(contentsOf: appSettingsOptionDetailBlock(candidate))
                }
            }
        }

        if truncated {
            lines.append("")
            lines.append("Result truncated by limit. Increase `limit` up to 200 or filter by `agent`.")
        }

        if !notes.isEmpty {
            lines.append("")
            lines.append("### Notes")
            for note in notes {
                lines.append("- \(note)")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Returns true if an options candidate object carries any of the richer
    /// fields the service emits for `detailed=true` option responses. Used to
    /// switch `formatAppSettingsOptions` into the richer per-candidate layout
    /// without depending on request arguments alone.
    private static func appSettingsOptionCarriesDetailedFields(_ candidate: [String: Value]) -> Bool {
        if trimmedAppSettingsString(candidate["description"]?.stringValue) != nil { return true }
        if trimmedAppSettingsString(candidate["reasoning_effort"]?.stringValue) != nil { return true }
        if candidate["context_window_tokens"]?.intValue != nil { return true }
        if let tags = candidate["tags"]?.arrayValue, !tags.isEmpty { return true }
        return false
    }

    /// Render a per-candidate detail block (header + bullet list) surfacing the
    /// richer fields from `op=options detailed=true`. Assumes the caller has
    /// already verified at least one detail field is present.
    private static func appSettingsOptionDetailBlock(_ candidate: [String: Value]) -> [String] {
        let label = trimmedAppSettingsString(candidate["label"]?.stringValue)
        let valueSummary: String? = {
            guard let value = candidate["value"] else { return nil }
            return AppSettingValueFormatter.summaryForMarkdown(value, maxChars: 80)
        }()
        let header = switch (label, valueSummary) {
        case let (label?, valueSummary?):
            "#### \(label) — \(valueSummary)"
        case let (label?, nil):
            "#### \(label)"
        case let (nil, valueSummary?):
            "#### \(valueSummary)"
        case (nil, nil):
            "#### Option"
        }

        var bullets: [String] = []
        if let description = trimmedAppSettingsString(candidate["description"]?.stringValue) {
            bullets.append("- **Description**: \(description)")
        }
        if let effort = trimmedAppSettingsString(candidate["reasoning_effort"]?.stringValue) {
            bullets.append("- **Reasoning effort**: `\(effort)`")
        }
        if let tokens = candidate["context_window_tokens"]?.intValue {
            bullets.append("- **Context window**: \(formatAppSettingsTokenCount(tokens)) tokens")
        }
        if let tagsArray = candidate["tags"]?.arrayValue {
            let tagStrings = tagsArray.compactMap { trimmedAppSettingsString($0.stringValue) }
            let joined = tagStrings.isEmpty ? "—" : tagStrings.joined(separator: ", ")
            bullets.append("- **Tags**: \(joined)")
        }

        return [header] + bullets
    }

    /// Locale-independent thousands-separated formatter for token counts
    /// (e.g., 128000 → "128,000"). Keeps output stable for tests that assert on
    /// the rendered number.
    private static func formatAppSettingsTokenCount(_ tokens: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: tokens)) ?? "\(tokens)"
    }

    private static func formatAppSettingsFailure(args: [String: Value], object: [String: Value], op: String?) -> String {
        let effectiveOp = op ?? normalizedAppSettingsOp(args["op"]?.stringValue)
        let key = trimmedAppSettingsString(object["key"]?.stringValue)
            ?? trimmedAppSettingsString(args["key"]?.stringValue)
        let rawIssue = trimmedAppSettingsString(object["error"]?.stringValue)
            ?? trimmedAppSettingsString(object["message"]?.stringValue)
            ?? appSettingsContentText(object)
            ?? "Request failed."
        let issue: String = if let key {
            "Key: `\(key)` — \(rawIssue)"
        } else {
            rawIssue
        }
        return operationFailed(
            title: "App Settings Failed",
            issue: issue,
            troubleshooting: appSettingsTroubleshooting(op: effectiveOp)
        )
    }

    private static func appSettingsTroubleshooting(op: String?) -> [String] {
        switch op {
        case "set":
            [
                "Re-run with a supported value from the allowlist.",
                "For JSON payloads, quote string values and use `null` for optional models."
            ]
        case "get":
            [
                "Re-run `app_settings op=list` to confirm supported keys."
            ]
        case "list":
            [
                "Re-run `app_settings op=list` without filters to inspect the catalog."
            ]
        case "options":
            [
                "Run `app_settings op=list group=models` to confirm `options_available` for the key.",
                "Pass exactly one `key` and optional `agent`/`limit`/`detailed` filters.",
                "Use `app_settings op=set key=... value=<option.value>`; pass `value=null` to clear optional model settings."
            ]
        default:
            [
                "Re-run `app_settings op=list` to inspect supported groups, keys, and values."
            ]
        }
    }

    private static func appSettingsContentText(_ object: [String: Value]) -> String? {
        guard let content = object["content"]?.arrayValue else { return nil }
        let parts = content.compactMap { block -> String? in
            guard let blockObject = block.objectValue else { return nil }
            if let type = blockObject["type"]?.stringValue, type.lowercased() != "text" {
                return nil
            }
            return trimmedAppSettingsString(blockObject["text"]?.stringValue)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private static func appSettingsAllowedValuesSummary(_ values: [String]) -> String {
        let visible = values.prefix(6).joined(separator: ", ")
        let omitted = values.count - min(values.count, 6)
        return omitted > 0 ? "\(visible), … (+\(omitted) more)" : visible
    }

    private static func appSettingsDisplayType(_ raw: String?) -> String {
        switch trimmedAppSettingsString(raw)?.lowercased() {
        case "boolean", "bool":
            "bool"
        case "string|null", "optionalstring":
            "string|null"
        case let type?:
            type
        case nil:
            "value"
        }
    }

    private static func appSettingsUsefulDescription(_ raw: String?, key: String) -> String? {
        guard let description = trimmedAppSettingsString(raw) else { return nil }
        let compactDescription = truncateAppSettings(description, limit: 120)
        let keyTerms = key.split(separator: ".").last.map { String($0).replacingOccurrences(of: "_", with: " ").lowercased() } ?? key.lowercased()
        let normalizedDescription = description.lowercased()
        if normalizedDescription == keyTerms || normalizedDescription == "\(keyTerms)." {
            return nil
        }
        return compactDescription
    }

    private static func appSettingsDetailedFlag(args: [String: Value], object: [String: Value]) -> Bool {
        if let detailed = args["detailed"]?.boolValue {
            return detailed
        }
        if let detailed = object["detailed"]?.boolValue {
            return detailed
        }
        return true
    }

    private static func normalizedAppSettingsOp(_ raw: String?) -> String? {
        guard let raw = trimmedAppSettingsString(raw)?.lowercased(), !raw.isEmpty else { return nil }
        return raw
    }

    private static func trimmedAppSettingsString(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func truncateAppSettings(_ string: String, limit: Int) -> String {
        guard string.count > limit else { return string }
        return "\(string.prefix(max(0, limit - 1)))…"
    }

    private static func escapeMarkdownTableCell(_ string: String) -> String {
        string.replacingOccurrences(of: "|", with: "\\|")
    }

    private struct BindContextBindingDTO: Decodable {
        let bindingKind: String
        let windowID: Int?
        let contextID: String?
        let workspaceName: String?
        let tabName: String?
        let repoPaths: [String]?
        let explicit: Bool?
        let runScoped: Bool?

        enum CodingKeys: String, CodingKey {
            case bindingKind = "binding_kind"
            case windowID = "window_id"
            case contextID = "context_id"
            case workspaceName = "workspace_name"
            case tabName = "tab_name"
            case repoPaths = "repo_paths"
            case explicit
            case runScoped = "run_scoped"
        }
    }

    private struct BindContextTabDTO: Decodable {
        let contextID: String
        let name: String
        let isActive: Bool
        let isBound: Bool
        let repoPaths: [String]?

        enum CodingKeys: String, CodingKey {
            case contextID = "context_id"
            case name
            case isActive = "is_active"
            case isBound = "is_bound"
            case repoPaths = "repo_paths"
        }
    }

    private struct BindContextWindowDTO: Decodable {
        let windowID: Int
        let isCurrentWindow: Bool
        let workspace: WorkspaceDTO?
        let activeContextID: String?
        let tabs: [BindContextTabDTO]

        struct WorkspaceDTO: Decodable {
            let id: String?
            let name: String
        }

        enum CodingKeys: String, CodingKey {
            case windowID = "window_id"
            case isCurrentWindow = "is_current_window"
            case workspace
            case activeContextID = "active_context_id"
            case tabs
        }
    }

    private struct BindContextResponseDTO: Decodable {
        let windows: [BindContextWindowDTO]?
        let binding: BindContextBindingDTO
        let changed: Bool?
        let previousBinding: BindContextBindingDTO?
        let matchedBy: String?
        let createdTab: Bool?
        let createdWorkspace: Bool?
        let normalizedWorkingDirs: [String]?
        let note: String?

        enum CodingKeys: String, CodingKey {
            case windows
            case binding
            case changed
            case previousBinding = "previous_binding"
            case matchedBy = "matched_by"
            case createdTab = "created_tab"
            case createdWorkspace = "created_workspace"
            case normalizedWorkingDirs = "normalized_working_dirs"
            case note
        }
    }

    private static func bindingSummaryLine(_ binding: BindContextBindingDTO) -> String {
        switch binding.bindingKind {
        case "tab_context":
            let tab = binding.tabName ?? binding.contextID ?? "(unknown tab)"
            let window = binding.windowID.map { "window \($0)" } ?? "unknown window"
            let workspace = binding.workspaceName.map { " • workspace \($0)" } ?? ""
            let flags: [String] = [binding.explicit == true ? "explicit" : nil, binding.runScoped == true ? "run-scoped" : nil].compactMap(\.self)
            let flagSuffix = flags.isEmpty ? "" : " • " + flags.joined(separator: ", ")
            return "Tab context \(tab) in \(window)\(workspace)\(flagSuffix)"
        case "window":
            let window = binding.windowID.map { "window \($0)" } ?? "unknown window"
            let workspace = binding.workspaceName.map { " • workspace \($0)" } ?? ""
            return "Window-only affinity to \(window)\(workspace)"
        default:
            return "Unbound"
        }
    }

    static func formatBindContext(args: [String: Value], value: Value) -> [MCP.Tool.Content] {
        guard let dto = value.decode(BindContextResponseDTO.self) else {
            return formatGeneric(value: value)
        }
        let op = args["op"]?.stringValue?.lowercased() ?? "status"
        var out: [String] = []
        out.append("## Tab Context Binding \(statusIcon(success: dto.binding.bindingKind != "unbound" || op == "list" || op == "status"))")
        out.append("- **Binding**: \(bindingSummaryLine(dto.binding))")

        if let changed = dto.changed {
            out.append("- **Changed**: \(changed ? "yes" : "no")")
        }
        if let matchedBy = dto.matchedBy, !matchedBy.isEmpty {
            out.append("- **Matched by**: \(matchedBy)")
        }
        if let createdTab = dto.createdTab {
            out.append("- **Created tab**: \(createdTab ? "yes" : "no")")
        }
        if let createdWorkspace = dto.createdWorkspace {
            out.append("- **Created workspace**: \(createdWorkspace ? "yes" : "no")")
        }
        if let dirs = dto.normalizedWorkingDirs, !dirs.isEmpty {
            out.append("- **Normalized working_dirs**: \(dirs.map { "`\($0)`" }.joined(separator: ", "))")
        }
        if let note = dto.note, !note.isEmpty {
            out.append("- **Note**: \(note)")
        }
        if let previous = dto.previousBinding {
            out.append("- **Previous binding**: \(bindingSummaryLine(previous))")
        }

        if let windows = dto.windows {
            let isFiltered = args["window_id"] != nil
            out.append("")
            out.append("### Windows")
            out.append("- **Count**: \(windows.count)\(isFiltered ? " (filtered by window_id)" : "")")
            if !windows.isEmpty {
                out.append("")
            }

            // For unfiltered multi-window lists, use compact format to reduce token usage
            let useCompactFormat = !isFiltered && windows.count > 1
            for window in windows {
                var title = "- Window `\(window.windowID)`"
                if window.isCurrentWindow { title += " [current]" }
                if let workspaceName = window.workspace?.name, !workspaceName.isEmpty {
                    title += " • workspace: \(workspaceName)"
                }
                let tabCount = window.tabs.count
                if useCompactFormat {
                    title += " • \(tabCount) tab\(tabCount == 1 ? "" : "s")"
                }
                out.append(title)

                if useCompactFormat {
                    // Compact: show repo paths, active tab, and bound tabs
                    if let repoPath = window.tabs.first?.repoPaths?.first, !repoPath.isEmpty {
                        out.append("  repo: `\(repoPath)`")
                    }
                    if let activeContextID = window.activeContextID, !activeContextID.isEmpty {
                        let activeTab = window.tabs.first(where: { $0.isActive })
                        let activeName = activeTab?.name ?? "active"
                        out.append("  • active: \(activeName) — context_id: `\(activeContextID)`")
                    }
                    let boundTabs = window.tabs.filter { $0.isBound && !$0.isActive }
                    for tab in boundTabs {
                        out.append("  • bound: \(tab.name) — context_id: `\(tab.contextID)`")
                    }
                } else {
                    // Detailed: show all tabs (single window or explicit filter)
                    if let activeContextID = window.activeContextID, !activeContextID.isEmpty {
                        out.append("  • active_context_id: `\(activeContextID)`")
                    }
                    if window.tabs.isEmpty {
                        out.append("  • 0 tabs")
                        continue
                    }
                    for tab in window.tabs {
                        var flags: [String] = []
                        if tab.isActive { flags.append("active") }
                        if tab.isBound { flags.append("bound") }
                        let flagSuffix = flags.isEmpty ? "" : " [\(flags.joined(separator: ", "))]"
                        out.append("  • \(tab.name)\(flagSuffix) — context_id: `\(tab.contextID)`")
                        if let repoPath = tab.repoPaths?.first, !repoPath.isEmpty {
                            out.append("    repo: `\(repoPath)`")
                        }
                    }
                }
            }
        }

        if op == "list" {
            out.append("")
            out.append("### Next Steps")
            out.append("- Use `bind_context` with `op=bind` and a `context_id` to bind a specific tab context.")
            out.append("- Or use `bind_context` with `op=bind` and a `window_id` to set window affinity.")
            if let windows = dto.windows, windows.count > 1 {
                out.append("- Use `window_id` filter on `op=list` to see all tabs in a specific window.")
            }
        }

        return [.text(out.joined(separator: "\n"))]
    }

    static func formatReadFile(args: [String: Value], value: Value) -> [MCP.Tool.Content] {
        let path = args["path"]?.stringValue ?? "(unknown)"
        let lang = languageTag(forPath: path)
        // Preferred DTO decoding
        if let dto = value.decode(ToolResultDTOs.ReadFileReply.self) {
            let displayPath = dto.displayPath ?? path
            let text = readFile(
                path: displayPath,
                first: dto.firstLine,
                last: dto.lastLine,
                total: dto.totalLines,
                language: lang,
                message: dto.message,
                content: dto.content,
                worktreeScope: dto.worktreeScope
            )
            return [.text(text)]
        }
        // Fallback: value is an object with expected keys but decode failed
        if case let .object(obj) = value {
            let content = obj["content"]?.stringValue ?? ""
            let total = obj["total_lines"]?.intValue
                ?? Int(obj["total_lines"]?.stringValue ?? "")
                ?? content.components(separatedBy: "\n").count
            let first = obj["first_line"]?.intValue
                ?? Int(obj["first_line"]?.stringValue ?? "")
                ?? (content.isEmpty ? 0 : 1)
            let last = obj["last_line"]?.intValue
                ?? Int(obj["last_line"]?.stringValue ?? "")
                ?? total
            let message = obj["message"]?.stringValue
            let text = readFile(
                path: path,
                first: first,
                last: last,
                total: total,
                language: lang,
                message: message,
                content: content
            )
            return [.text(text)]
        }
        // Fallback: legacy string response (assume whole content)
        if let s = value.stringValue {
            let lines = s.isEmpty ? 0 : s.components(separatedBy: "\n").count
            let text = readFile(
                path: path,
                first: lines == 0 ? 0 : 1,
                last: lines,
                total: lines,
                language: lang,
                message: "Legacy format (no slice metadata)",
                content: s
            )
            return [.text(text)]
        }
        // Final fallback: present JSON
        return formatGeneric(value: value)
    }

    static func formatChatLog(value: Value, emitResources: Bool) -> [MCP.Tool.Content] {
        guard case let .object(obj) = value, let arr = obj["messages"]?.arrayValue else {
            return formatGeneric(value: value)
        }
        let chatID = obj["chat_id"]?.stringValue
        let scope = obj["scope"]?.stringValue
        let contextID = obj["context_id"]?.stringValue ?? obj["tab_id"]?.stringValue
        var entries: [(role: String, text: String, diffs: [(path: String, patch: String)])] = []
        for v in arr {
            guard let o = v.objectValue else { continue }
            let role = o["role"]?.stringValue
            let text = o["text"]?.stringValue ?? ""
            let diffs = o["diffs"].map { parseDiffArray($0.arrayValue ?? []) } ?? []
            entries.append((role ?? "message", text, diffs))
        }
        // Build human-readable log with text + optional diffs
        var out: [String] = []
        out.append("## Chat Log \(statusIcon(success: true))")
        if let chatID, !chatID.isEmpty { out.append("- **Chat**: `\(chatID)`") }
        if let scope, !scope.isEmpty { out.append("- **Scope**: \(scope)") }
        if let contextID, !contextID.isEmpty { out.append("- **Context**: `\(contextID)`") }
        for (i, e) in entries.enumerated() {
            out.append("")
            out.append("### Message #\(i + 1) — \(e.role)")
            if !e.text.isEmpty {
                out.append("\n```text\n\(e.text)\n```")
            }
            if !e.diffs.isEmpty {
                out.append("")
                out.append("#### Diffs")
                for d in e.diffs {
                    out.append("Patch for `\(d.path)`:\n\n```diff\n\(d.patch)\n```")
                }
            }
        }
        var blocks: [MCP.Tool.Content] = [.text(out.joined(separator: "\n"))]
        if emitResources {
            for (i, e) in entries.enumerated() where !e.diffs.isEmpty {
                var combined = "Message #\(i + 1) patches:\n"
                for d in e.diffs {
                    combined += "\n--- \(d.path) ---\n```diff\n\(d.patch)\n```"
                }
                blocks.append(.text(combined))
            }
        }
        return blocks
    }

    static func formatOracleChatLog(args: [String: Value], value: Value, emitResources: Bool) -> [MCP.Tool.Content] {
        _ = emitResources
        guard case let .object(obj) = value, let arr = obj["messages"]?.arrayValue else {
            return formatGeneric(value: value)
        }

        let chatID = obj["chat_id"]?.stringValue
        let includeUser = args["include_user"]?.boolValue ?? false
        var entries: [(role: String, text: String)] = []
        for v in arr {
            guard let o = v.objectValue else { continue }
            let role = o["role"]?.stringValue ?? "message"
            let text = o["text"]?.stringValue ?? ""
            entries.append((role, text))
        }

        var out: [String] = []
        out.append("## Oracle Chat Log \(statusIcon(success: true))")
        if let chatID, !chatID.isEmpty {
            out.append("- **Chat**: `\(chatID)`")
        }
        out.append("- **Messages**: \(entries.count)")
        out.append("- **Includes user messages**: \(includeUser ? "yes" : "no")")

        for (index, entry) in entries.enumerated() {
            out.append("")
            out.append("### Message #\(index + 1) — \(entry.role)")
            if !entry.text.isEmpty {
                out.append("\n```text\n\(entry.text)\n```")
            }
        }

        return [.text(out.joined(separator: "\n"))]
    }

    static func formatChatList(value: Value) -> [MCP.Tool.Content] {
        // Expect { chats: [ { id, name, last_modified, message_count, selected_files, is_current, is_active_for_tab, context_id? }, ... ] }
        guard case let .object(obj) = value, let chatsArr = obj["chats"]?.arrayValue else {
            return formatGeneric(value: value)
        }
        var out: [String] = []
        out.reserveCapacity(8 + chatsArr.count * 2)
        out.append("## Chats \(statusIcon(success: true))")
        out.append("- **Count**: \(chatsArr.count)")
        if let scope = obj["scope"]?.stringValue, !scope.isEmpty {
            out.append("- **Scope**: \(scope)")
        }
        if let contextID = obj["context_id"]?.stringValue ?? obj["tab_id"]?.stringValue, !contextID.isEmpty {
            out.append("- **Context**: `\(contextID)`")
        }
        if !chatsArr.isEmpty {
            out.append("")
            out.append("### Sessions")
            for v in chatsArr {
                guard let o = v.objectValue else { continue }
                let id = o["id"]?.stringValue ?? ""
                let name = o["name"]?.stringValue ?? "(untitled)"
                let last = o["last_modified"]?.stringValue ?? ""
                let msgs = o["message_count"]?.intValue ?? 0
                let contextID = o["context_id"]?.stringValue ?? o["tab_id"]?.stringValue ?? ""
                let cur = o["is_current"]?.boolValue ?? false
                let activeForTab = o["is_active_for_tab"]?.boolValue ?? false
                let markers = [cur ? "⭐ current" : nil, activeForTab ? "📌 active-for-tab" : nil].compactMap(\.self).joined(separator: ", ")
                let files = o["selected_files"]?.arrayValue?.compactMap(\.stringValue) ?? []
                let filesCount = files.count
                let preview = files.prefix(5)
                let extra = filesCount - preview.count
                let filesPreviewText: String = {
                    if filesCount == 0 { return "files=0" }
                    let list = preview.joined(separator: ", ")
                    return extra > 0 ? "files=\(filesCount): \(list) … (+\(extra) more)" : "files=\(filesCount): \(list)"
                }()
                let contextPreview: String = {
                    guard !contextID.isEmpty else { return "" }
                    let shortContext = contextID.count > 8 ? "\(contextID.prefix(8))…" : contextID
                    return " — context=\(shortContext)"
                }()
                let markerText = markers.isEmpty ? "" : " [\(markers)]"
                out.append("• [\(id)] \(name)\(markerText) — \(msgs) msgs — \(filesPreviewText)\(contextPreview) — \(last)")
            }
        }
        return [.text(out.joined(separator: "\n"))]
    }

    // (formatRequestPlan removed)

    static func formatApplyEdits(value: Value, emitResources: Bool) -> [MCP.Tool.Content] {
        let formatState = EditFlowPerf.begin(EditFlowPerf.Stage.ApplyEdits.format)
        defer { EditFlowPerf.end(EditFlowPerf.Stage.ApplyEdits.format, formatState) }

        let dto: ToolResultDTOs.EditSummary? = EditFlowPerf.measure(EditFlowPerf.Stage.ApplyEdits.formatDecode) {
            value.decode(ToolResultDTOs.EditSummary.self)
        }
        if let dto {
            var outBlocks: [String] = []
            outBlocks.reserveCapacity(dto.results?.isEmpty == false ? 4 : 2)
            // Summary
            let summary = EditFlowPerf.measure(
                EditFlowPerf.Stage.ApplyEdits.formatMarkdown,
                EditFlowPerf.Dimensions(fileBytes: dto.unifiedDiff?.utf8.count)
            ) {
                applyEdits(
                    editsRequested: dto.editsRequested,
                    editsApplied: dto.editsApplied,
                    linesChanged: dto.totalLinesChanged,
                    chunks: dto.totalChunks,
                    diff: dto.unifiedDiff
                )
            }
            outBlocks.append(summary)
            // Per-edit outcomes when provided (multi-edit and verbose single-edit)
            if let results = dto.results, !results.isEmpty {
                var lines: [String] = []
                lines.reserveCapacity(results.count + 2)
                lines.append("### Outcomes")
                for r in results {
                    let idx = r.index + 1
                    if let err = r.error, !err.isEmpty {
                        lines.append("- Edit \(idx): failed – \(err)")
                    } else {
                        lines.append("- Edit \(idx): success")
                    }
                }
                outBlocks.append(lines.joined(separator: "\n"))
            }
            // Optional context notes (e.g. fallback creation / overwrite)
            if (dto.fileCreated == true) || (dto.fileOverwritten == true) || (dto.note?.isEmpty == false) {
                var notes: [String] = []
                notes.reserveCapacity(4)
                notes.append("### Notes")
                if dto.fileCreated == true {
                    notes.append("- File was missing; created because `on_missing=create`.")
                }
                if dto.fileOverwritten == true {
                    notes.append("- Target file existed; content overwritten due to `if_exists=overwrite`.")
                }
                if let n = dto.note, !n.isEmpty {
                    notes.append("- \(n)")
                }
                outBlocks.append(notes.joined(separator: "\n"))
            }
            if dto.requiresUserApproval == true {
                var reviewLines: [String] = []
                reviewLines.reserveCapacity(4)
                reviewLines.append("### Review")
                if let status = dto.reviewStatus, !status.isEmpty {
                    reviewLines.append("- Outcome: \(status)")
                }
                if let reason = dto.rejectionReason, !reason.isEmpty {
                    reviewLines.append("- Reason: \(reason)")
                }
                reviewLines.append("- User approval was required.")
                outBlocks.append(reviewLines.joined(separator: "\n"))
            }
            var blocks: [MCP.Tool.Content] = [.text(outBlocks.joined(separator: "\n\n"))]
            // Optionally emit an extra diff block as a separate text content (safe textual "resource")
            if emitResources, let diff = dto.unifiedDiff, !diff.isEmpty {
                let diffBlock = EditFlowPerf.measure(
                    EditFlowPerf.Stage.ApplyEdits.formatResource,
                    EditFlowPerf.Dimensions(fileBytes: diff.utf8.count)
                ) {
                    MCP.Tool.Content.text("```diff\n\(diff)\n```")
                }
                blocks.append(diffBlock)
            }
            return blocks
        }
        // Fallback: object with "unified_diff" or legacy string
        if case let .object(obj) = value {
            let requested = obj["edits_requested"]?.intValue
            let applied = obj["edits_applied"]?.intValue
            let lines = obj["total_lines_changed"]?.intValue
                ?? Int(obj["total_lines_changed"]?.stringValue ?? "")
            let chunks = obj["total_chunks"]?.intValue
                ?? Int(obj["total_chunks"]?.stringValue ?? "")
            let diff = obj["unified_diff"]?.stringValue
            let reviewStatus = obj["review_status"]?.stringValue
            let rejectionReason = obj["rejection_reason"]?.stringValue
            let requiresUserApproval = obj["requires_user_approval"]?.boolValue
            var outBlocks: [String] = []
            outBlocks.reserveCapacity((obj["results"]?.arrayValue?.isEmpty == false) ? 3 : 2)
            let summary = EditFlowPerf.measure(
                EditFlowPerf.Stage.ApplyEdits.formatMarkdown,
                EditFlowPerf.Dimensions(fileBytes: diff?.utf8.count)
            ) {
                applyEdits(
                    editsRequested: requested,
                    editsApplied: applied,
                    linesChanged: lines,
                    chunks: chunks,
                    diff: diff
                )
            }
            outBlocks.append(summary)
            // Per-edit outcomes if present in fallback object
            if let arr = obj["results"]?.arrayValue {
                var lines: [String] = []
                lines.reserveCapacity(arr.count + 2)
                lines.append("### Outcomes")
                for v in arr {
                    guard let o = v.objectValue else { continue }
                    let idx = (o["index"]?.intValue ?? 0) + 1
                    let status = o["status"]?.stringValue ?? "failed"
                    let err = o["error"]?.stringValue ?? ""
                    if status.lowercased() == "failed" {
                        let msg = err.isEmpty ? "unknown error" : err
                        lines.append("- Edit \(idx): failed – \(msg)")
                    } else {
                        lines.append("- Edit \(idx): success")
                    }
                }
                outBlocks.append(lines.joined(separator: "\n"))
            }
            if requiresUserApproval == true {
                var reviewLines: [String] = []
                reviewLines.reserveCapacity(4)
                reviewLines.append("### Review")
                if let reviewStatus, !reviewStatus.isEmpty {
                    reviewLines.append("- Outcome: \(reviewStatus)")
                }
                if let rejectionReason, !rejectionReason.isEmpty {
                    reviewLines.append("- Reason: \(rejectionReason)")
                }
                reviewLines.append("- User approval was required.")
                outBlocks.append(reviewLines.joined(separator: "\n"))
            }
            var blocks: [MCP.Tool.Content] = [.text(outBlocks.joined(separator: "\n\n"))]
            if emitResources, let d = diff, !d.isEmpty {
                let diffBlock = EditFlowPerf.measure(
                    EditFlowPerf.Stage.ApplyEdits.formatResource,
                    EditFlowPerf.Dimensions(fileBytes: d.utf8.count)
                ) {
                    MCP.Tool.Content.text("```diff\n\(d)\n```")
                }
                blocks.append(diffBlock)
            }
            return blocks
        }
        if let s = value.stringValue {
            // Legacy: return as-is under Apply Edits heading
            let text = applyEdits(editsRequested: nil, editsApplied: nil, linesChanged: nil, chunks: nil, diff: s)
            return [.text(text)]
        }
        return formatGeneric(value: value)
    }

    static func formatFileTree(value: Value) -> [MCP.Tool.Content] {
        if let dto = value.decode(ToolResultDTOs.FileTreeDTO.self) {
            let text = fileTreeSummary(rootsCount: dto.rootsCount, usesLegend: dto.usesLegend, tree: dto.tree, note: dto.note, worktreeScope: dto.worktreeScope)
            return [.text(text)]
        }
        if let s = value.stringValue {
            // Legacy fallback: do not infer legends here; return raw tree text
            return [.text(s)]
        }
        return formatGeneric(value: value)
    }

    static func formatChatSend(args: [String: Value], value: Value, emitResources: Bool) -> [MCP.Tool.Content] {
        var shortId: String? = args["chat_id"]?.stringValue
        var mode = args["mode"]?.stringValue
        var response: String?
        var diffs: [(path: String, patch: String)] = []
        var errors: [String] = []
        var oracleExportPath: String?
        var oracleExportInstruction: String?

        switch value {
        case let .string(s):
            response = s
        case let .object(obj):
            // Prefer result object fields when present
            shortId = obj["chat_id"]?.stringValue ?? shortId
            mode = obj["mode"]?.stringValue ?? mode
            response = obj["response"]?.stringValue ?? obj["message"]?.stringValue ?? obj["text"]?.stringValue
            if let arr = obj["diffs"]?.arrayValue ?? obj["patches"]?.arrayValue {
                diffs = parseDiffArray(arr)
            }
            if let errArr = obj["errors"]?.arrayValue {
                errors = errArr.compactMap(\.stringValue)
            }
            oracleExportPath = obj["oracle_export_path"]?.stringValue
            oracleExportInstruction = obj["oracle_export_instruction"]?.stringValue
            // Nested result support
            if response == nil, let res = obj["result"] {
                if let s = res.stringValue { response = s }
                else if let arr = res.objectValue?["diffs"]?.arrayValue { diffs = parseDiffArray(arr) }
            }
        case let .array(arr):
            // Could be an array of patch objects
            diffs = parseDiffArray(arr)
        default:
            break
        }

        // Build main section using our existing helper
        let text = chatSend(chatId: shortId, mode: mode, response: response, diffs: diffs)
        var blocks: [MCP.Tool.Content] = [.text(text)]
        if let handoffBlock = oracleExportBlock(path: oracleExportPath, instruction: oracleExportInstruction) {
            blocks.append(.text(handoffBlock))
        }
        // Append errors section if any
        if !errors.isEmpty {
            var lines: [String] = []
            lines.reserveCapacity(errors.count + 2)
            lines.append("")
            lines.append("### Errors")
            for e in errors {
                lines.append("- \(e)")
            }
            blocks.append(.text(lines.joined(separator: "\n")))
        }
        if emitResources, !diffs.isEmpty {
            // Add each diff as its own fenced block to aid client rendering
            for d in diffs {
                blocks.append(.text("Patch for `\(d.path)`:\n```diff\n\(d.patch)\n```"))
            }
        }
        return blocks
    }

    private static func oracleExportBlock(path: String?, instruction: String?) -> String? {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        // The formatter runs in the caller's context but does not know
        // which delegation tool that caller sees. Keep the wording
        // tool-agnostic and point back at the system prompt, which
        // branches on `taskLabelKind` to name the correct tool for this
        // caller. See AgentModePrompts.Fragments.agentRunExportGuidance
        // / agentExploreExportGuidance for the authoritative per-role
        // copy and docs/reviews/export-path-instructions-by-agent-type.md
        // for the design.
        var lines: [String] = []
        lines.append("### Oracle export")
        lines.append("- Path: `\(path)`")
        lines.append("- To share this with a delegated agent, include the path inside the `message` you send on your next delegation call; your system prompt names the specific delegation tool you should use. The child agent opens the file with `read_file`.")
        if let instruction, !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("")
            lines.append("```text")
            lines.append(instruction)
            lines.append("```")
        }
        return lines.joined(separator: "\n")
    }

    static func formatAskOracle(args: [String: Value], value: Value, emitResources: Bool) -> [MCP.Tool.Content] {
        var shortId: String? = args["chat_id"]?.stringValue
        var mode = args["mode"]?.stringValue
        var response: String?
        var diffs: [(path: String, patch: String)] = []
        var errors: [String] = []
        var oracleExportPath: String?
        var oracleExportInstruction: String?

        switch value {
        case let .string(s):
            response = s
        case let .object(obj):
            shortId = obj["chat_id"]?.stringValue ?? shortId
            mode = obj["mode"]?.stringValue ?? mode
            response = obj["response"]?.stringValue ?? obj["message"]?.stringValue ?? obj["text"]?.stringValue
            if let arr = obj["diffs"]?.arrayValue ?? obj["patches"]?.arrayValue {
                diffs = parseDiffArray(arr)
            }
            if let errArr = obj["errors"]?.arrayValue {
                errors = errArr.compactMap(\.stringValue)
            }
            oracleExportPath = obj["oracle_export_path"]?.stringValue
            oracleExportInstruction = obj["oracle_export_instruction"]?.stringValue
            if response == nil, let res = obj["result"] {
                if let s = res.stringValue { response = s }
                else if let arr = res.objectValue?["diffs"]?.arrayValue { diffs = parseDiffArray(arr) }
            }
        case let .array(arr):
            diffs = parseDiffArray(arr)
        default:
            break
        }

        let text = askOracle(chatId: shortId, mode: mode, response: response, diffs: diffs)
        var blocks: [MCP.Tool.Content] = [.text(text)]
        if let handoffBlock = oracleExportBlock(path: oracleExportPath, instruction: oracleExportInstruction) {
            blocks.append(.text(handoffBlock))
        }
        if !errors.isEmpty {
            var lines: [String] = []
            lines.reserveCapacity(errors.count + 2)
            lines.append("")
            lines.append("### Errors")
            for e in errors {
                lines.append("- \(e)")
            }
            blocks.append(.text(lines.joined(separator: "\n")))
        }
        if emitResources, !diffs.isEmpty {
            for d in diffs {
                blocks.append(.text("Patch for `\(d.path)`:\n```diff\n\(d.patch)\n```"))
            }
        }
        return blocks
    }

    static func formatPromptState(value: Value) -> [MCP.Tool.Content] {
        // Forwarded prompt-tool envelope (e.g. workspace_context op=list_presets/export/select_preset)
        if value.decode(ToolResultDTOs.PromptToolEnvelope.self) != nil {
            return formatPrompt(value: value)
        }

        // New unified DTO
        if let ctx = value.decode(ToolResultDTOs.PromptContextDTO.self) {
            var out: [String] = []
            let selectionCount = ctx.selection?.files.count ?? 0
            let blockCount = ctx.fileBlocks?.count ?? 0
            out.reserveCapacity(20 + selectionCount * 3 + blockCount)
            out.append("## Prompt Context \(statusIcon(success: true))")

            // Copy preset info (active vs effective if overridden)
            if let preset = ctx.copyPreset {
                if preset.isOverridden {
                    out.append("- **Copy Preset**: \(preset.effective.name) (overriding \(preset.active.name))")
                } else {
                    out.append("- **Copy Preset**: \(preset.active.name)")
                }
            }
            out.append(contentsOf: worktreeScopeLines(ctx.worktreeScope, operation: .workspaceContext))

            // Token breakdown - organized by category
            if let ts = ctx.tokenStats {
                out.append("**\(formatTokenCount(ts.total)) total tokens**")
                out.append("")

                // Selection section (files + codemaps)
                let hasFilesBreakdown = (ts.filesContent != nil && ts.filesContent! > 0) || (ts.codemaps != nil && ts.codemaps! > 0)
                if hasFilesBreakdown {
                    out.append("- **Selection**: \(formatTokenCount(ts.files))")
                    if let filesContent = ts.filesContent, filesContent > 0 {
                        out.append("  - Files: \(formatTokenCount(filesContent))")
                    }
                    if let codemaps = ts.codemaps, codemaps > 0 {
                        out.append("  - Codemaps: \(formatTokenCount(codemaps))")
                    }
                } else if ts.files > 0 {
                    out.append("- **Selection**: \(formatTokenCount(ts.files))")
                }

                // Other workspace components
                if let prompt = ts.prompt, prompt > 0 {
                    out.append("- Prompt: \(formatTokenCount(prompt))")
                }
                if let tree = ts.fileTree, tree > 0 {
                    out.append("- File tree: \(formatTokenCount(tree))")
                }
                if let meta = ts.meta, meta > 0 {
                    out.append("- Stored prompts: \(formatTokenCount(meta))")
                }
                if let git = ts.git, git > 0 {
                    out.append("- Git: \(formatTokenCount(git))")
                }
            }
            if let sel = ctx.selection {
                if let summary = sel.summary {
                    let totalCount = summary.fullCount + summary.sliceCount + summary.codemapCount
                    let countBreakdown = selectionCountBreakdownText(summary)
                    if totalCount > 0 {
                        if countBreakdown.isEmpty {
                            out.append("- **Selected files**: \(totalCount) total")
                        } else {
                            out.append("- **Selected files**: \(totalCount) total (\(countBreakdown))")
                        }
                    }
                    // Skip "Selected tokens" when tokenStats is present - it already shows "Files tokens" which is the same value
                    if ctx.tokenStats == nil {
                        out.append("- **Selected tokens**: \(sel.totalTokens)")
                    }
                    let tokenBreakdown = selectionTokenBreakdownText(summary)
                    if !tokenBreakdown.isEmpty {
                        out.append("- Token breakdown: \(tokenBreakdown)")
                    }
                } else {
                    // When no summary, show combined line only if tokenStats is absent
                    if ctx.tokenStats == nil {
                        out.append("- **Selected files**: \(sel.files.count) • **Selected tokens**: \(sel.totalTokens)")
                    } else {
                        out.append("- **Selected files**: \(sel.files.count)")
                    }
                }
            }

            // Prompt block
            if !ctx.prompt.isEmpty {
                out.append("")
                out.append("### Prompt")
                out.append("```text\n\(ctx.prompt)\n```")
            }

            // Selection - folder-grouped with copy preset divergence
            if let sel = ctx.selection, !sel.files.isEmpty {
                out.append("")
                out.append("### Selection")
                out.append("\(sel.files.count) files \u{2022} \(formatTokenCount(sel.totalTokens)) tokens (Auto view)")

                // Copy preset effect (only if it differs from auto)
                if let copyMode = sel.userCopyCodeMapUsage, copyMode != "auto" {
                    out.append("")
                    // Count files that would be included in copy preset (not hidden)
                    let copyFileCount = sel.files.count(where: { file in
                        if let cp = file.copyPreset, cp.renderMode == "hidden" {
                            return false
                        }
                        return true
                    })

                    if let copyTokens = sel.userCopyTokens {
                        let delta = copyTokens - sel.totalTokens
                        let deltaText = delta < 0 ? "down ~\(formatTokenCount(-delta))" : "up ~\(formatTokenCount(delta))"
                        out.append("Copy preset: \(copyMode) \u{2022} \(copyFileCount) files \u{2022} ~\(formatTokenCount(copyTokens)) tokens (\(deltaText))")
                    } else {
                        out.append("Copy preset: \(copyMode) \u{2022} \(copyFileCount) files")
                    }
                    out.append(copyPresetExplanation(mode: copyMode))
                }

                out.append("")
                out.append(contentsOf: selectionFolderGroupedLines(files: sel.files))
            } else if let slices = ctx.selection?.fileSlices, !slices.isEmpty {
                out.append("")
                out.append("### Selection Slices")
                out.append(contentsOf: selectionSlicesLines(slices: slices))
            }

            // Selected file tree (already ASCII)
            if let tree = ctx.fileTree, !tree.tree.isEmpty {
                out.append("")
                out.append("### Selected File Tree")
                out.append(tree.tree)
            }

            // Selected code structure (codemaps, default)
            if let cs = ctx.codeStructure {
                out.append("")
                out.append("### Code Maps")
                out.append("- **Files with codemap**: \(cs.fileCount)")
                // Keep output efficient: only emit full codemap content for small selections
                let showContent = cs.fileCount <= 10 && !cs.content.isEmpty
                if showContent {
                    out.append("")
                    out.append("```text\n\(cs.content)\n```")
                } else if cs.fileCount > 10 {
                    out.append("")
                    out.append("_Codemap details omitted for large selections. Use `get_code_structure` for a full listing._")
                }
            }

            // Optional raw file content blocks
            if let blocks = ctx.fileBlocks, !blocks.isEmpty {
                out.append("")
                out.append("### Selected File Contents")
                out.append(blocks.joined(separator: "\n\n"))
            }

            return [.text(out.joined(separator: "\n"))]
        }

        // Legacy fallback
        if let dto = value.decode(ToolResultDTOs.PromptStateReply.self) {
            let text = promptState(prompt: dto.prompt, selectedPaths: dto.selectedPaths, fileSlices: dto.fileSlices)
            return [.text(text)]
        }
        if case let .object(obj) = value,
           obj["prompt"] != nil || obj["selected_paths"] != nil || obj["file_slices"] != nil
        {
            let prompt = obj["prompt"]?.stringValue ?? ""
            let paths = obj["selected_paths"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let text = promptState(prompt: prompt, selectedPaths: paths)
            return [.text(text)]
        }
        if let s = value.stringValue {
            return [.text("## Prompt State \(statusIcon(success: true))\n\(s)")]
        }
        return formatGeneric(value: value)
    }

    // MARK: - Prompt

    static func formatPrompt(value: Value) -> [MCP.Tool.Content] {
        // Try envelope first (new format)
        if let envelope = value.decode(ToolResultDTOs.PromptToolEnvelope.self) {
            if let exportReply = envelope.export {
                return formatPromptExport(exportReply)
            } else if let promptReply = envelope.prompt {
                return formatPromptReply(promptReply)
            } else if let presetsList = envelope.presetsList {
                return formatPresetsList(presetsList.presets)
            } else if let selectedPreset = envelope.selectedPreset {
                return formatSelectedPreset(selectedPreset)
            }
        }
        // Fallback: try direct PromptExportReply (legacy)
        if let dto = value.decode(ToolResultDTOs.PromptExportReply.self) {
            return formatPromptExport(dto)
        }
        // Fallback: try direct PromptReply (legacy)
        if let dto = value.decode(ToolResultDTOs.PromptReply.self) {
            return formatPromptReply(dto)
        }
        return formatGeneric(value: value)
    }

    private static func formatPromptExport(_ dto: ToolResultDTOs.PromptExportReply) -> [MCP.Tool.Content] {
        var out: [String] = []
        out.reserveCapacity(10 + dto.files.count * 2)
        out.append("## Prompt Export \(statusIcon(success: true))")
        out.append("- **Path**: `\(dto.path)`")
        if let preset = dto.copyPreset {
            let kindInfo = preset.kind != nil ? " (\(preset.kind!))" : ""
            out.append("- **Copy Preset**: \(preset.name)\(kindInfo)")
        }
        out.append("- **Files**: \(dto.files.count)")
        out.append("- **Tokens**: \(formatTokenCount(dto.tokens))")
        out.append("- **Bytes**: \(dto.bytes)")
        if !dto.files.isEmpty {
            out.append("")
            out.append(contentsOf: selectionFolderGroupedLines(files: dto.files))
        }
        return [.text(out.joined(separator: "\n"))]
    }

    private static func formatPresetsList(_ presets: [ToolResultDTOs.CopyPresetListItemDTO]) -> [MCP.Tool.Content] {
        var out: [String] = []
        out.reserveCapacity(presets.count * 4 + 5)
        out.append("## Copy Presets \(statusIcon(success: true))")
        out.append("**\(presets.count) presets available**")
        out.append("")

        for preset in presets {
            let icon = preset.icon ?? ""
            let kindInfo = preset.preset.kind != nil ? " (\(preset.preset.kind!))" : ""
            let builtInTag = preset.preset.isBuiltIn ? " [built-in]" : ""
            out.append("### \(icon) \(preset.preset.name)\(kindInfo)\(builtInTag)")
            out.append("- **ID**: `\(preset.preset.id)`")
            if let desc = preset.description, !desc.isEmpty {
                out.append("- \(desc)")
            }

            // Configuration summary
            var config: [String] = []
            if let includeFiles = preset.includeFiles {
                config.append("files: \(includeFiles ? "yes" : "no")")
            }
            if let codeMapUsage = preset.codeMapUsage, codeMapUsage != "auto" {
                config.append("codemap: \(codeMapUsage)")
            }
            if let fileTreeMode = preset.fileTreeMode, fileTreeMode != "auto" {
                config.append("tree: \(fileTreeMode)")
            }
            if let gitInclusion = preset.gitInclusion, gitInclusion != "none" {
                config.append("git: \(gitInclusion)")
            }
            if !config.isEmpty {
                out.append("- Config: \(config.joined(separator: ", "))")
            }
            out.append("")
        }

        return [.text(out.joined(separator: "\n"))]
    }

    private static func formatSelectedPreset(_ preset: ToolResultDTOs.CopyPresetDescriptorDTO) -> [MCP.Tool.Content] {
        var out: [String] = []
        out.append("## Copy Preset Selected \(statusIcon(success: true))")
        let kindInfo = preset.kind != nil ? " (\(preset.kind!))" : ""
        let builtInTag = preset.isBuiltIn ? " [built-in]" : ""
        out.append("- **Preset**: \(preset.name)\(kindInfo)\(builtInTag)")
        out.append("- **ID**: `\(preset.id)`")
        return [.text(out.joined(separator: "\n"))]
    }

    private static func formatPromptReply(_ dto: ToolResultDTOs.PromptReply) -> [MCP.Tool.Content] {
        var out: [String] = []
        out.reserveCapacity(18)
        out.append("## Prompt \(statusIcon(success: true))")
        out.append("- **Lines**: \(dto.lines)")

        // Preset information
        if let copyPresetName = dto.copyPresetName,
           let chatPresetName = dto.chatPresetName,
           let chatMode = dto.chatMode
        {
            out.append("")
            out.append("### Active Presets")
            out.append("- **Copy Preset**: \(copyPresetName)")
            out.append("- **Chat Preset**: \(chatPresetName)")
            out.append("- **Chat Mode**: \(chatMode)")
        }

        // Configuration breakdown
        if let includesFiles = dto.includesFiles {
            out.append("")
            out.append("### Configuration")

            // What's included
            var includes: [String] = []
            if includesFiles { includes.append("Files") }
            if dto.includesFileTree == true { includes.append("File Tree") }
            if dto.includesCodemaps == true { includes.append("Code Maps") }
            if dto.includesGitDiff == true { includes.append("Git Diff") }
            if dto.includesUserPrompt == true { includes.append("User Prompt") }
            if dto.includesMetaPrompts == true { includes.append("Meta Prompts") }
            if dto.includesStoredPrompts == true { includes.append("Stored Prompts") }

            if !includes.isEmpty {
                out.append("- **Includes**: \(includes.joined(separator: ", "))")
            }

            // Detailed settings
            if let fileTreeMode = dto.fileTreeMode {
                out.append("- **File Tree Mode**: \(fileTreeMode)")
            }
            if let codeMapUsage = dto.codeMapUsage, codeMapUsage != "none" {
                out.append("- **Code Map Usage**: \(codeMapUsage)")
            }
            if let gitInclusion = dto.gitInclusion, gitInclusion != "none" {
                out.append("- **Git Inclusion**: \(gitInclusion)")
            }
        }

        // Token counts
        if let effectiveTokens = dto.effectiveTokens {
            out.append("")
            out.append("### Token Counts")
            out.append("- **Effective Tokens**: \(effectiveTokens) (current context)")
            if let fullFilesTokens = dto.fullFilesTokens, fullFilesTokens != effectiveTokens {
                out.append("- **Full Files Tokens**: \(fullFilesTokens) (if full files included)")
            }
        }

        // Code maps — concise, consistent, not verbose here
        if let codeMapFileCount = dto.codeMapFileCount, codeMapFileCount > 0 {
            out.append("")
            out.append("### Code Maps")
            if let codeMapTokens = dto.codeMapTokens {
                out.append("- **Files**: \(codeMapFileCount) • **Tokens**: \(codeMapTokens)")
            } else {
                out.append("- **Files**: \(codeMapFileCount)")
            }
            // Deliberately avoid listing files here to keep this surface lean.
            out.append("- To see which files have codemaps, use `manage_selection` (op=`get`, view=`files`) or `workspace_context` (include=`[\"selection\",\"code\"]`) for more detail.")
        }

        // Prompt content
        if !dto.prompt.isEmpty {
            out.append("")
            out.append("### Prompt")
            out.append("```text\n\(dto.prompt)\n```")
        }

        return [.text(out.joined(separator: "\n"))]
    }

    static func formatCodeStructure(value: Value) -> [MCP.Tool.Content] {
        if let dto = value.decode(ToolResultDTOs.SelectedCodeStructureDTO.self) {
            let maxResultsOmitted = dto.omittedCount ?? 0
            let tokenBudgetOmitted = dto.tokenBudgetOmittedCount ?? 0
            let totalOmitted = dto.omittedTotal ?? (maxResultsOmitted + tokenBudgetOmitted)
            let hasRenderableResult = dto.fileCount > 0 || totalOmitted > 0
            let hasPendingRepair = dto.pendingPaths?.isEmpty == false
            var out: [String] = []
            out.append("## Code Structure \(statusIcon(success: hasRenderableResult, warning: hasPendingRepair))")
            out.append("- **Files with codemap**: \(dto.fileCount)")
            switch (maxResultsOmitted, tokenBudgetOmitted) {
            case let (maxOmitted, 0) where maxOmitted > 0:
                out.append("- **Codemaps omitted**: \(maxOmitted) (increase `max_results` to inspect more files)")
            case let (0, budgetOmitted) where budgetOmitted > 0:
                out.append("- **Codemaps omitted**: \(budgetOmitted) (response capped near 6k tokens; narrow `paths` or request specific files/directories)")
            case let (maxOmitted, budgetOmitted) where maxOmitted > 0 && budgetOmitted > 0:
                out.append("- **Codemaps omitted**: \(totalOmitted) (\(maxOmitted) beyond `max_results`, \(budgetOmitted) beyond the ~6k-token response cap)")
                out.append("- **Guidance**: Increase `max_results` to consider more files, or narrow `paths` to change which files fit inside the response cap.")
            default:
                break
            }
            out.append(contentsOf: worktreeScopeLines(dto.worktreeScope, operation: .codeStructure))
            if let pending = dto.pendingPaths, !pending.isEmpty {
                out.append("- **Codemap repair pending**: \(pending.count) (bounded wait expired; retry with narrower `paths` if needed)")
                out.append("")
                out.append("### Files still awaiting codemap")
                let grouped = groupPathsByRoot(pending)
                for (root, paths) in grouped {
                    out.append("- **\(root)**")
                    for p in paths {
                        out.append("  - `\(p)`")
                    }
                }
            }
            if let unmapped = dto.unmappedPaths, !unmapped.isEmpty {
                out.append("- **Without codemap**: \(unmapped.count)")
                out.append("")
                out.append("### Files without codemap")
                let grouped = groupPathsByRoot(unmapped)
                for (root, paths) in grouped {
                    out.append("- **\(root)**")
                    for p in paths {
                        out.append("  - `\(p)`")
                    }
                }
            }
            if !dto.content.isEmpty { out.append("")
                out.append("```text\n\(dto.content)\n```")
            }
            return [.text(out.joined(separator: "\n"))]
        }
        if let s = value.stringValue {
            var out: [String] = []
            let count = s.isEmpty ? 0 : 1
            out.append("## Code Structure \(statusIcon(success: count > 0))")
            out.append("- **Files**: \(count)")
            if !s.isEmpty { out.append("")
                out.append("```text\n\(s)\n```")
            }
            return [.text(out.joined(separator: "\n"))]
        }
        return formatGeneric(value: value)
    }

    // (Removed) formatTokenStats – token stats are part of workspace_context

    static func formatListModels(value: Value) -> [MCP.Tool.Content] {
        if let dto = value.decode(ToolResultDTOs.ListModelsReply.self) {
            var out: [String] = []
            out.append("## Models \(statusIcon(success: !dto.models.isEmpty))")
            out.append("- **Count**: \(dto.models.count)")
            if !dto.models.isEmpty {
                out.append("")
                for m in dto.models {
                    let modesText: String
                    if let sm = m.supportedModes {
                        var modes: [String] = []
                        if sm.chat { modes.append("chat") }
                        if sm.plan { modes.append("plan") }
                        if sm.review { modes.append("review") }
                        modesText = modes.isEmpty ? "unknown" : modes.joined(separator: ", ")
                    } else {
                        modesText = "unknown"
                    }
                    let descText = (m.description?.isEmpty == false) ? " — \(m.description!)" : ""
                    out.append("- `\(m.id)`: \(m.name) — modes: \(modesText)\(descText)")
                }
            }
            return [.text(out.joined(separator: "\n"))]
        }
        // Fallbacks: legacy plain list string or array
        if let s = value.stringValue {
            return [.text("## Models \(statusIcon(success: !s.isEmpty))\n\(s)")]
        }
        if case let .array(arr) = value {
            let entries: [(id: String, name: String, desc: String?)] = arr.compactMap { v in
                if let o = v.objectValue {
                    let id = o["id"]?.stringValue ?? ""
                    let name = o["name"]?.stringValue ?? ""
                    let desc = o["description"]?.stringValue
                    if id.isEmpty, name.isEmpty { return nil }
                    return (id, name, desc)
                }
                return nil
            }
            if !entries.isEmpty {
                let text = models(entries)
                return [.text(text)]
            }
        }
        return formatGeneric(value: value)
    }

    /// Formats a SelectionReply to a string for embedding in other responses
    static func formatSelectionReplyToString(_ dto: ToolResultDTOs.SelectionReply) -> String {
        var out: [String] = []
        let fileCount = dto.files?.count ?? 0
        let rangeLookup = selectionRangeLookup(from: dto.fileSlices)
        out.reserveCapacity(12 + fileCount * 3)

        if let summary = dto.summary {
            let totalCount = summary.fullCount + summary.sliceCount + summary.codemapCount
            let countBreakdown = selectionCountBreakdownText(summary)
            if totalCount > 0 {
                if countBreakdown.isEmpty {
                    out.append("- Files: \(totalCount) total")
                } else {
                    out.append("- Files: \(totalCount) total (\(countBreakdown))")
                }
            }
            let totalTokens = dto.totalTokens ?? (summary.fullTokens + summary.sliceTokens + summary.codemapTokens)
            out.append("- Total tokens: \(totalTokens) (Auto view)")
            let tokenBreakdown = selectionTokenBreakdownText(summary)
            if !tokenBreakdown.isEmpty {
                out.append("- Token breakdown: \(tokenBreakdown)")
            }
        } else {
            if let files = dto.files {
                out.append("- Files: \(files.count)")
            }
            if let total = dto.totalTokens {
                out.append("- Total tokens: \(total) (Auto view)")
            }
        }

        // Copy preset effect (only if it differs from auto)
        if let copyMode = dto.userCopyCodeMapUsage, copyMode != "auto", let files = dto.files {
            // Count files that would be included in copy preset (not hidden)
            let copyFileCount = files.count(where: { file in
                if let cp = file.copyPreset, cp.renderMode == "hidden" {
                    return false
                }
                return true
            })

            if let copyTokens = dto.userCopyTokens {
                let delta = copyTokens - (dto.totalTokens ?? 0)
                let deltaText = delta < 0 ? "down ~\(formatTokenCount(-delta))" : "up ~\(formatTokenCount(delta))"
                out.append("- Copy preset: \(copyMode) • \(copyFileCount) files • ~\(formatTokenCount(copyTokens)) tokens (\(deltaText))")
            } else {
                out.append("- Copy preset: \(copyMode) • \(copyFileCount) files")
            }
        }

        if let files = dto.files, !files.isEmpty {
            out.append("")
            out.append("### Files")
            out.append(contentsOf: selectionFolderGroupedLines(files: files, rangeLookup: rangeLookup))
        } else if let slices = dto.fileSlices, !slices.isEmpty {
            out.append("")
            out.append("### Selection Slices")
            out.append(contentsOf: selectionSlicesLines(slices: slices))
        }

        return out.joined(separator: "\n")
    }

    static func formatManageSelection(args: [String: Value], value: Value) -> [MCP.Tool.Content] {
        let action = args["action"]?.stringValue?.lowercased()
            ?? args["op"]?.stringValue?.lowercased()
            ?? "get"
        if let dto = value.decode(ToolResultDTOs.SelectionReply.self) {
            var out: [String] = []
            let fileCount = dto.files?.count ?? 0
            let blockCount = dto.blocks?.count ?? 0
            out.reserveCapacity(20 + fileCount * 4 + blockCount)

            // Compute totals
            let fileTokens = dto.totalTokens ?? 0
            let autoTotal = dto.tokenStats?.total ?? fileTokens
            let copyPresetTokens = dto.userCopyTokens ?? fileTokens
            let otherTokens = autoTotal - fileTokens // prompt + tree + meta + git
            let actualTotal = copyPresetTokens + otherTokens
            let copyMode = dto.userCopyCodeMapUsage ?? "auto"
            let isNonAutoMode = copyMode != "auto"

            // Header
            out.append("## Selection \(statusIcon(success: true))")
            out.append("**\(formatTokenCount(actualTotal)) total tokens**")

            if let ts = dto.tokenStats {
                out.append("")

                // Count visible vs hidden files
                let visibleFiles = dto.files?.count(where: { file in
                    if let cp = file.copyPreset, cp.renderMode == "hidden" { return false }
                    return true
                }) ?? fileCount
                let hiddenFiles = fileCount - visibleFiles

                // Files section - show what's actually in the prompt
                if isNonAutoMode {
                    // Show actual file tokens based on user's mode
                    var fileDesc = "\(visibleFiles) file\(visibleFiles == 1 ? "" : "s")"
                    if hiddenFiles > 0 {
                        fileDesc += ", \(hiddenFiles) hidden"
                    }
                    out.append("Files: \(formatTokenCount(copyPresetTokens)) (\(fileDesc))")

                    // Show auto view as reference for MCP tools
                    let hasFilesBreakdown = (ts.filesContent != nil && ts.filesContent! > 0) || (ts.codemaps != nil && ts.codemaps! > 0)
                    if hasFilesBreakdown {
                        var parts: [String] = []
                        if let fc = ts.filesContent, fc > 0 { parts.append("\(formatTokenCount(fc)) full") }
                        if let cm = ts.codemaps, cm > 0 { parts.append("\(formatTokenCount(cm)) codemaps") }
                        out.append("  (auto view: \(formatTokenCount(ts.files)) = \(parts.joined(separator: " + ")))")
                    }
                } else {
                    // Auto mode - show breakdown directly
                    let hasFilesBreakdown = (ts.filesContent != nil && ts.filesContent! > 0) || (ts.codemaps != nil && ts.codemaps! > 0)
                    if hasFilesBreakdown {
                        var parts: [String] = []
                        if let fc = ts.filesContent, fc > 0 { parts.append("\(formatTokenCount(fc)) full") }
                        if let cm = ts.codemaps, cm > 0 { parts.append("\(formatTokenCount(cm)) codemaps") }
                        out.append("Files: \(formatTokenCount(ts.files)) (\(parts.joined(separator: " + ")))")
                    } else if ts.files > 0 {
                        out.append("Files: \(formatTokenCount(ts.files))")
                    }
                }

                // Other components (compact single line)
                var otherParts: [String] = []
                if let prompt = ts.prompt, prompt > 0 { otherParts.append("prompt \(formatTokenCount(prompt))") }
                if let fileTree = ts.fileTree, fileTree > 0 { otherParts.append("tree \(formatTokenCount(fileTree))") }
                if let meta = ts.meta, meta > 0 { otherParts.append("stored \(formatTokenCount(meta))") }
                if let git = ts.git, git > 0 { otherParts.append("git \(formatTokenCount(git))") }
                if !otherParts.isEmpty {
                    out.append("Other: \(otherParts.joined(separator: ", "))")
                }

                // Mode explanation (only for non-auto modes)
                if isNonAutoMode {
                    out.append("")
                    switch copyMode {
                    case "selected":
                        out.append("_Mode: \(copyMode) — files with codemaps render as codemaps; codemap-only files hidden_")
                    case "complete":
                        out.append("_Mode: \(copyMode) — all files with codemaps render as codemaps_")
                    case "none":
                        out.append("_Mode: \(copyMode) — full file content only, no codemaps_")
                    default:
                        out.append("_Mode: \(copyMode)_")
                    }
                }
            }

            // Invalid paths
            if let invalid = dto.invalidPaths, !invalid.isEmpty {
                out.append("")
                for p in invalid {
                    out.append("Invalid: \(p)")
                }
            }

            let rangeLookup = selectionRangeLookup(from: dto.fileSlices)

            // Folder-grouped file listing
            if let files = dto.files, !files.isEmpty {
                out.append("")
                out.append(contentsOf: selectionFolderGroupedLines(files: files, rangeLookup: rangeLookup))
            } else if let slices = dto.fileSlices, !slices.isEmpty {
                out.append("")
                out.append("### Selection Slices")
                out.append(contentsOf: selectionSlicesLines(slices: slices))
            }

            // Code maps summary (if present)
            if let cs = dto.codeStructure, cs.fileCount > 0 {
                out.append("")
                out.append("Code Maps: \(cs.fileCount) files")
            }

            // File content blocks (if requested)
            if let blocks = dto.blocks, !blocks.isEmpty {
                out.append("")
                out.append("---")
                out.append(blocks.joined(separator: "\n\n"))
            }

            return [.text(out.joined(separator: "\n"))]
        }
        // Fallbacks unchanged…
        if case let .object(obj) = value {
            var out: [String] = []
            out.append("## Selection")
            if let status = obj["status"]?.stringValue { out.append("Status: \(status)") }
            if let total = obj["total_tokens"]?.intValue ?? Int(obj["totalTokens"]?.stringValue ?? "") {
                out.append("Total tokens: \(total)")
            }
            if let filesArr = obj["files"]?.arrayValue {
                out.append("Files: \(filesArr.count)")
                out.append("")
                for v in filesArr {
                    if let o = v.objectValue {
                        let p = o["path"]?.stringValue ?? ""
                        let t = o["tokens"]?.intValue ?? 0
                        if !p.isEmpty { out.append("  \(p) \u{2014} \(t) tokens") }
                    } else if let p = v.stringValue {
                        out.append("  \(p)")
                    }
                }
            }
            if let invalidArr = obj["invalid_paths"]?.arrayValue, !invalidArr.isEmpty {
                out.append("")
                for v in invalidArr {
                    if let p = v.stringValue { out.append("Invalid: \(p)") }
                }
            }
            return [.text(out.joined(separator: "\n"))]
        }
        if let s = value.stringValue {
            return [.text("## Selection\n\(s)")]
        }
        return formatGeneric(value: value)
    }

    /// Formats token count with thousands separator (fast path avoids NumberFormatter allocation)
    private static func formatTokenCount(_ count: Int) -> String {
        if #available(macOS 12.0, iOS 15.0, *) {
            count.formatted(.number.grouping(.automatic))
        } else {
            legacyTokenFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
        }
    }

    private static let legacyTokenFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f
    }()

    /// Returns explanation text for copy preset mode
    private static func copyPresetExplanation(mode: String) -> String {
        switch mode.lowercased() {
        case "selected":
            "Selected mode copies codemaps when available to reduce tokens."
        case "complete":
            "Complete mode includes ALL workspace files with codemaps (not shown above)."
        case "none":
            "None mode uses full file content (no codemaps)."
        default:
            ""
        }
    }

    /// Formats file render description (full, lines X-Y, or origin for codemaps)
    private static func fileRenderDescription(
        info: ToolResultDTOs.SelectedFileInfo,
        fallbackRanges: [ToolResultDTOs.LineRangeDTO]? = nil
    ) -> String {
        let effectiveRanges = info.ranges ?? fallbackRanges
        switch info.renderMode {
        case "full":
            if let effectiveRanges, !effectiveRanges.isEmpty {
                let formatted = formatRanges(effectiveRanges)
                return "lines \(formatted)"
            }
            return "full"
        case "slice":
            if let effectiveRanges, !effectiveRanges.isEmpty {
                let formatted = formatRanges(effectiveRanges)
                return "lines \(formatted)"
            }
            return "slice"
        case "codemap":
            // For codemaps, just show origin since section header says "Codemaps"
            if let origin = info.codemapOrigin {
                switch origin {
                case "auto":
                    return "auto"
                case "manual":
                    return "manual"
                case "selected_mode":
                    return "selected"
                default:
                    return origin
                }
            }
            return ""
        default:
            return info.renderMode
        }
    }

    // MARK: - Tree-based Selection Rendering

    /// Node in a generic path tree (folder or item leaf)
    private enum PathTreeNode<Item> {
        case folder(name: String, children: [PathTreeNode<Item>])
        case file(item: Item, name: String)
    }

    /// Builds a nested tree structure from flat path items
    private static func buildPathTree<Item>(
        items: [Item],
        path: (Item) -> String,
        forcedPrefix: String? = nil
    ) -> (commonPrefix: String, roots: [PathTreeNode<Item>]) {
        guard !items.isEmpty else { return ("", []) }

        // Find common prefix path. `split(separator:)` drops the empty leading
        // component for absolute paths, so track absoluteness separately and
        // restore the leading slash when rendering the shared prefix.
        let rawPaths = items.map { path($0) }
        let allAbsolute = rawPaths.allSatisfy { $0.hasPrefix("/") }
        let pathComponents = rawPaths.map { $0.split(separator: "/").map(String.init) }
        var commonPrefix: [String] = []
        if let first = pathComponents.first {
            for (i, component) in first.enumerated() {
                if pathComponents.allSatisfy({ $0.count > i && $0[i] == component }) {
                    commonPrefix.append(component)
                } else {
                    break
                }
            }
        }
        // If the prefix is the full path (single file), drop the filename component
        if items.count == 1, !commonPrefix.isEmpty {
            commonPrefix.removeLast()
        }
        let prefixPath: String
        if let forcedPrefix {
            prefixPath = forcedPrefix
        } else {
            let displayPrefixComponents = pathTreeDisplayRootComponents(
                fromCommonPrefix: commonPrefix,
                allAbsolute: allAbsolute
            )
            let joinedPrefix = displayPrefixComponents.joined(separator: "/")
            prefixPath = if allAbsolute {
                joinedPrefix.isEmpty ? "/" : "/\(joinedPrefix)"
            } else {
                joinedPrefix
            }
        }

        /// Recursively build tree nodes from files relative to prefix
        func buildNodes(from items: [Item], prefix: String) -> [PathTreeNode<Item>] {
            var folders: [String: [Item]] = [:]
            var directItems: [Item] = []

            for item in items {
                // Get path relative to prefix
                let fullPath = path(item)
                let relativePath: String
                if prefix.isEmpty {
                    relativePath = fullPath
                } else if prefix == "/", fullPath.hasPrefix("/") {
                    relativePath = String(fullPath.dropFirst())
                } else if fullPath.hasPrefix(prefix + "/") {
                    relativePath = String(fullPath.dropFirst(prefix.count + 1))
                } else {
                    // File doesn't match prefix - treat as direct file
                    directItems.append(item)
                    continue
                }

                let parts = relativePath.split(separator: "/").map(String.init)
                if parts.count == 1 {
                    directItems.append(item)
                } else if parts.count > 1, let firstFolder = parts.first {
                    folders[firstFolder, default: []].append(item)
                } else if parts.isEmpty {
                    // Empty relative path - shouldn't happen but handle gracefully
                    directItems.append(item)
                }
            }

            var nodes: [PathTreeNode<Item>] = []

            // Add folders first (sorted)
            for folderName in folders.keys.sorted() {
                let folderItems = folders[folderName]!
                let newPrefix: String = if prefix.isEmpty {
                    folderName
                } else if prefix == "/" {
                    "/\(folderName)"
                } else {
                    "\(prefix)/\(folderName)"
                }
                let children = buildNodes(from: folderItems, prefix: newPrefix)
                nodes.append(.folder(name: folderName, children: children))
            }

            // Add files (sorted)
            for item in directItems.sorted(by: { path($0) < path($1) }) {
                let itemPath = path(item)
                let fileName = itemPath.split(separator: "/").last.map(String.init) ?? itemPath
                nodes.append(.file(item: item, name: fileName))
            }

            return nodes
        }

        let roots = buildNodes(from: items, prefix: prefixPath)
        return (prefixPath, roots)
    }

    /// Chooses the inferred root/header line for generic path trees when no exact root metadata exists.
    private static func pathTreeDisplayRootComponents(
        fromCommonPrefix commonPrefix: [String],
        allAbsolute: Bool
    ) -> [String] {
        guard !commonPrefix.isEmpty else { return [] }
        guard allAbsolute else {
            return commonPrefix.count > 1 ? [commonPrefix[0]] : commonPrefix
        }
        return commonPrefix
    }

    /// Renders a path tree with proper connectors
    private static func renderPathTree<Item>(
        nodes: [PathTreeNode<Item>],
        basePath: String = "",
        relativePath: String = "",
        prefix: String = "",
        compactUnaryFolders: Bool = false,
        folderSuffix: ((String) -> String?)? = nil,
        fileLine: (Item, String) -> String,
        fileChildren: ((Item, String) -> [String])? = nil
    ) -> [String] {
        var lines: [String] = []

        func fullPath(for relative: String) -> String {
            guard !basePath.isEmpty else { return relative }
            guard basePath != "/" else { return "/\(relative)" }
            return "\(basePath)/\(relative)"
        }

        func compactedNode(_ node: PathTreeNode<Item>) -> (node: PathTreeNode<Item>, relativePath: String) {
            guard case let .folder(name, children) = node else { return (node, relativePath) }

            var currentRelative = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
            guard compactUnaryFolders else { return (node, currentRelative) }

            var displayParts = [name]
            var currentChildren = children
            guard (folderSuffix?(fullPath(for: currentRelative)) ?? "").isEmpty else {
                return (node, currentRelative)
            }

            while currentChildren.count == 1 {
                switch currentChildren[0] {
                case let .folder(childName, grandchildren):
                    let childRelative = "\(currentRelative)/\(childName)"
                    if !(folderSuffix?(fullPath(for: childRelative)) ?? "").isEmpty {
                        return (.folder(name: displayParts.joined(separator: "/"), children: currentChildren), currentRelative)
                    }
                    displayParts.append(childName)
                    currentRelative = childRelative
                    currentChildren = grandchildren

                case let .file(item, fileName):
                    displayParts.append(fileName)
                    return (.file(item: item, name: displayParts.joined(separator: "/")), "\(currentRelative)/\(fileName)")
                }
            }

            return (.folder(name: displayParts.joined(separator: "/"), children: currentChildren), currentRelative)
        }

        for (index, originalNode) in nodes.enumerated() {
            let isLast = index == nodes.count - 1
            let connector = isLast ? "└── " : "├── "
            let childPrefix = prefix + (isLast ? "    " : "│   ")
            let (node, nodeRelativePath) = compactedNode(originalNode)

            switch node {
            case let .folder(name, children):
                let suffix = folderSuffix?(fullPath(for: nodeRelativePath)) ?? ""
                lines.append("\(prefix)\(connector)\(name)/\(suffix)")
                lines.append(contentsOf: renderPathTree(
                    nodes: children,
                    basePath: basePath,
                    relativePath: nodeRelativePath,
                    prefix: childPrefix,
                    compactUnaryFolders: compactUnaryFolders,
                    folderSuffix: folderSuffix,
                    fileLine: fileLine,
                    fileChildren: fileChildren
                ))
            case let .file(item, name):
                lines.append("\(prefix)\(connector)\(fileLine(item, name))")
                if let fileChildren {
                    lines.append(contentsOf: fileChildren(item, childPrefix))
                }
            }
        }

        return lines
    }

    private struct SelectionRootGroup {
        let rootPath: String
        let files: [ToolResultDTOs.SelectedFileInfo]
    }

    /// Builds a nested tree structure from selection file paths
    private static func buildSelectionTree(files: [ToolResultDTOs.SelectedFileInfo]) -> (commonPrefix: String, roots: [PathTreeNode<ToolResultDTOs.SelectedFileInfo>]) {
        buildPathTree(items: files, path: { $0.path })
    }

    private static func normalizedRootPath(_ path: String) -> String {
        var normalized = (path as NSString).standardizingPath
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private static func normalizedPathWithinRoot(_ path: String) -> String {
        var normalized = path
        while normalized.hasPrefix("/") {
            normalized.removeFirst()
        }
        return normalized
    }

    private static func selectionRootGroups(from files: [ToolResultDTOs.SelectedFileInfo]) -> [SelectionRootGroup]? {
        var grouped: [String: [ToolResultDTOs.SelectedFileInfo]] = [:]
        grouped.reserveCapacity(files.count)

        for file in files {
            guard let rawRoot = file.rootPath, !rawRoot.isEmpty,
                  let rawPathWithinRoot = file.pathWithinRoot, !rawPathWithinRoot.isEmpty
            else {
                return nil
            }
            let rootPath = normalizedRootPath(rawRoot)
            guard rootPath.hasPrefix("/") else { return nil }
            grouped[rootPath, default: []].append(file)
        }

        return grouped.keys.sorted().map { rootPath in
            SelectionRootGroup(rootPath: rootPath, files: grouped[rootPath] ?? [])
        }
    }

    /// Renders the selection tree with proper tree connectors
    private static func renderSelectionTree(
        nodes: [PathTreeNode<ToolResultDTOs.SelectedFileInfo>],
        prefix: String = "",
        rangeLookup: [String: [ToolResultDTOs.LineRangeDTO]] = [:]
    ) -> [String] {
        renderPathTree(nodes: nodes, prefix: prefix, fileLine: { info, name in
            let renderDesc = fileRenderDescription(info: info, fallbackRanges: rangeLookup[info.path])
            var line = "\(name) \u{2014} \(formatTokenCount(info.tokens)) tokens (\(renderDesc))"

            // Add inline copy preset if different
            if let copyPreset = info.copyPreset {
                if copyPreset.renderMode == "hidden" {
                    line += " \u{2192} copy: hidden"
                } else {
                    let copyDesc = copyPreset.renderMode == "codemap" ? "codemap" : copyPreset.renderMode
                    line += " \u{2192} copy: \(formatTokenCount(copyPreset.tokens)) (\(copyDesc))"
                }
            }
            return line
        })
    }

    private static func selectionMarkdownTreeLines(
        files: [ToolResultDTOs.SelectedFileInfo],
        rangeLookup: [String: [ToolResultDTOs.LineRangeDTO]]
    ) -> [String] {
        if let rootGroups = selectionRootGroups(from: files) {
            var lines: [String] = []
            for group in rootGroups {
                lines.append("\(group.rootPath)/")
                let (_, roots) = buildPathTree(
                    items: group.files,
                    path: { normalizedPathWithinRoot($0.pathWithinRoot ?? $0.path) },
                    forcedPrefix: ""
                )
                lines.append(contentsOf: renderSelectionTree(nodes: roots, rangeLookup: rangeLookup))
            }
            return lines
        }

        let (prefix, roots) = buildSelectionTree(files: files)
        var lines: [String] = []
        if !prefix.isEmpty {
            lines.append(prefix == "/" ? "/" : "\(prefix)/")
        }
        lines.append(contentsOf: renderSelectionTree(nodes: roots, rangeLookup: rangeLookup))
        return lines
    }

    /// Builds folder-grouped file listing lines with tree structure, split into Selected Files and Codemaps sections
    private static func selectionFolderGroupedLines(
        files: [ToolResultDTOs.SelectedFileInfo],
        rangeLookup: [String: [ToolResultDTOs.LineRangeDTO]] = [:]
    ) -> [String] {
        guard !files.isEmpty else { return [] }

        // For very large selections, avoid building a deep tree (expensive with lots of codemaps).
        // Fall back to the simpler sectioned list.
        let maxTreeFiles = 300
        if files.count > maxTreeFiles {
            let showRootHeaders = Set(files.map { rootName(for: $0.path) }).count > 1
            return selectionSectionLines(
                files: files,
                rangeLookup: rangeLookup,
                showRootHeaders: showRootHeaders,
                style: .compact
            )
        }

        // Partition in one pass (avoids two full filters)
        var selectedFiles: [ToolResultDTOs.SelectedFileInfo] = []
        var codemapFiles: [ToolResultDTOs.SelectedFileInfo] = []
        selectedFiles.reserveCapacity(files.count)
        codemapFiles.reserveCapacity(min(files.count, 64))
        for f in files {
            switch f.renderMode {
            case "full", "slice":
                selectedFiles.append(f)
            case "codemap":
                codemapFiles.append(f)
            default:
                // Keep "other" with selected to avoid hiding information
                selectedFiles.append(f)
            }
        }

        var lines: [String] = []

        // Selected Files section
        if !selectedFiles.isEmpty {
            lines.append("### Selected Files")
            lines.append(contentsOf: selectionMarkdownTreeLines(files: selectedFiles, rangeLookup: rangeLookup))
        }

        // Codemaps section
        if !codemapFiles.isEmpty {
            if !selectedFiles.isEmpty {
                lines.append("") // Blank line between sections
            }
            lines.append("### Codemaps")
            lines.append(contentsOf: selectionMarkdownTreeLines(files: codemapFiles, rangeLookup: rangeLookup))
        }

        return lines
    }

    static func formatManageWorkspaces(args: [String: Value], value: Value) -> [MCP.Tool.Content] {
        let action = args["action"]?.stringValue?.lowercased() ?? ""

        // Try to decode using the ManageWorkspacesResponse structure
        if case let .object(obj) = value {
            let responseAction = obj["action"]?.stringValue?.lowercased() ?? action
            let status = obj["status"]?.stringValue ?? "ok"

            switch responseAction {
            case "list":
                // Format workspace list
                if let workspacesArr = obj["workspaces"]?.arrayValue {
                    var out: [String] = []
                    out.append("## Workspaces \(statusIcon(success: !workspacesArr.isEmpty))")
                    out.append("- **Count**: \(workspacesArr.count)")
                    if !workspacesArr.isEmpty {
                        out.append("")
                        for ws in workspacesArr {
                            guard let o = ws.objectValue else { continue }
                            let id = o["id"]?.stringValue ?? ""
                            let name = o["name"]?.stringValue ?? ""
                            let rootCount = o["root_count"]?.intValue ?? 0
                            let repoPaths = o["repo_paths"]?.arrayValue?.compactMap(\.stringValue) ?? []
                            let showingWindows = o["showing_window_ids"]?.arrayValue?.compactMap(\.intValue) ?? []
                            let isHidden = o["is_hidden"]?.boolValue ?? false
                            let hiddenText = isHidden ? " • hidden" : ""
                            let windowsText = showingWindows.isEmpty ? "" : " • showing in windows: \(showingWindows.map(String.init).joined(separator: ", "))"
                            out.append("- `\(id)` • \(name) — \(rootCount) root\(rootCount == 1 ? "" : "s")\(hiddenText)\(windowsText)")
                            // Show first 3 root paths as preview (full absolute paths)
                            for path in repoPaths.prefix(3) {
                                out.append("  └ `\(path)`")
                            }
                            if rootCount > 3 {
                                out.append("  └ ... and \(rootCount - 3) more")
                            }
                        }
                    }
                    out.append("")
                    if !(args["include_hidden"]?.boolValue ?? false) {
                        out.append("_Hidden workspaces are omitted by default. Use `workspace list --include-hidden` or `include_hidden=true` to show recoverable hidden workspaces._")
                    }
                    out.append("_Workspace inventory only. Use `bind_context` `op=list` for per-window tabs, context_ids, and current binding._")
                    return [.text(out.joined(separator: "\n"))]
                }

            case "switch":
                var out: [String] = []
                // Check if this was an open_in_new_window request
                let openedNewWindow = args["open_in_new_window"]?.boolValue ?? false
                // Get window_id from response (new window case) or args (explicit target)
                let responseWindowID = obj["window_id"]?.intValue
                let argsWindowID = args["window_id"]?.intValue

                if openedNewWindow, let newWindowID = responseWindowID {
                    out.append("## Workspace Opened in New Window ✅")
                    if let wsName = args["workspace"]?.stringValue {
                        out.append("- **Workspace**: \(wsName)")
                    }
                    out.append("- **New Window ID**: `\(newWindowID)`")
                    out.append("")
                    out.append("### Connection Binding")
                    out.append("Your connection has been automatically bound to the new window (ID: \(newWindowID)).")
                    out.append("All subsequent tool calls will target this window.")
                    out.append("")
                    out.append("### Next Steps")
                    out.append("- Use `bind_context` with `op=list` to see compose tabs and context_id values.")
                    out.append("- Use `-w \(newWindowID)` when invoking CLI commands to target this window.")
                } else {
                    out.append("## Workspace Switch ✅")
                    if let wsName = args["workspace"]?.stringValue {
                        out.append("- **Workspace**: \(wsName)")
                    }
                    if let windowID = argsWindowID {
                        out.append("- **Window**: \(windowID)")
                    }
                    out.append("")
                    out.append("### Next Steps")
                    out.append("- Your tools now operate in the switched workspace context.")
                    out.append("- Use `bind_context` with `op=list` to see compose tabs and context_id values.")
                }
                return [.text(out.joined(separator: "\n"))]

            case "create":
                var out: [String] = []
                let openedNewWindow = args["open_in_new_window"]?.boolValue ?? false
                let switchToCreated = args["switch_to_created"]?.boolValue ?? true
                let responseWindowID = obj["window_id"]?.intValue
                let argsWindowID = args["window_id"]?.intValue

                if openedNewWindow, let newWindowID = responseWindowID {
                    out.append("## Workspace Created in New Window ✅")
                    if let name = args["name"]?.stringValue {
                        out.append("- **Name**: \(name)")
                    }
                    out.append("- **New Window ID**: `\(newWindowID)`")
                    out.append("")
                    out.append("### Connection Binding")
                    out.append("Your connection has been automatically bound to the new window (ID: \(newWindowID)).")
                    out.append("All subsequent tool calls will target this window.")
                } else {
                    out.append("## Workspace Created ✅")
                    if let name = args["name"]?.stringValue {
                        out.append("- **Name**: \(name)")
                    }
                    if let windowID = argsWindowID {
                        out.append("- **Window**: \(windowID)")
                    }
                    if switchToCreated {
                        out.append("- **Switched**: active workspace is now the new workspace")
                    }
                }
                return [.text(out.joined(separator: "\n"))]

            case "hide", "unhide":
                let isHide = responseAction == "hide"
                var out: [String] = []
                out.append(isHide ? "## Workspace Hidden ✅" : "## Workspace Unhidden ✅")
                if let wsName = args["workspace"]?.stringValue {
                    out.append("- **Workspace**: \(wsName)")
                }
                if isHide {
                    out.append("- **Recoverability**: workspace data was not deleted; use `workspace list --include-hidden` and `workspace unhide <workspace>` to recover it.")
                }
                return [.text(out.joined(separator: "\n"))]

            case "delete":
                var out: [String] = []
                out.append("## Workspace Deleted ✅")
                if let wsName = args["workspace"]?.stringValue {
                    out.append("- **Workspace**: \(wsName)")
                }
                if let closedID = obj["closed_window_id"]?.intValue {
                    out.append("- **Closed Window**: `\(closedID)`")
                }
                return [.text(out.joined(separator: "\n"))]

            case "add_folder":
                var out: [String] = []
                out.append("## Folder Added ✅")
                if let path = args["folder_path"]?.stringValue {
                    out.append("- **Folder**: `\(path)`")
                }
                if let wsName = args["workspace"]?.stringValue {
                    out.append("- **Workspace**: \(wsName)")
                }
                return [.text(out.joined(separator: "\n"))]

            case "remove_folder":
                var out: [String] = []
                out.append("## Folder Removed ✅")
                if let path = args["folder_path"]?.stringValue {
                    out.append("- **Folder**: `\(path)`")
                }
                if let wsName = args["workspace"]?.stringValue {
                    out.append("- **Workspace**: \(wsName)")
                }
                return [.text(out.joined(separator: "\n"))]

            case "create_tab", "close_tab":
                guard let tabsArr = obj["tabs"]?.arrayValue,
                      let first = tabsArr.first?.objectValue
                else {
                    return formatGeneric(value: value)
                }
                let heading = responseAction == "create_tab" ? "## Tab Created ✅" : "## Tab Closed ✅"
                var out: [String] = [heading]
                if let name = first["name"]?.stringValue, !name.isEmpty {
                    out.append("- **Context**: \(name)")
                }
                if let id = first["id"]?.stringValue, !id.isEmpty {
                    out.append("- **ID**: `\(id)`")
                }
                if let contextID = first["context_id"]?.stringValue ?? first["contextID"]?.stringValue, !contextID.isEmpty {
                    out.append("- **Context ID**: `\(contextID)`")
                }
                if let workspaceName = first["workspace_name"]?.stringValue ?? first["workspaceName"]?.stringValue, !workspaceName.isEmpty {
                    out.append("- **Workspace**: \(workspaceName)")
                }
                if let windowID = first["window_id"]?.intValue ?? first["windowID"]?.intValue {
                    out.append("- **Window**: \(windowID)")
                }
                if responseAction == "create_tab" {
                    out.append("- **Bound to connection**: \((args["bind"]?.boolValue ?? true) ? "yes" : "no")")
                    out.append("- **Focused in UI**: \((args["focus"]?.boolValue ?? false) ? "yes" : "no")")
                }
                return [.text(out.joined(separator: "\n"))]

            default:
                break
            }
        }

        // Fallback to generic
        return formatGeneric(value: value)
    }

    static func formatDiscoverContext(value: Value) -> [MCP.Tool.Content] {
        if case let .object(obj) = value {
            var out: [String] = []
            if let statusStr = obj["status"]?.stringValue {
                let statusLower = statusStr.lowercased()
                if statusLower != "completed" {
                    let icon = statusLower == "cancelled" ? "⚠️" : statusIcon(success: false)
                    out.append("## Discover Context \(icon)")
                    out.append("- Status: \(statusStr)")
                }
            }
            if let prompt = obj["prompt"]?.stringValue, !prompt.isEmpty {
                if !out.isEmpty {
                    out.append("")
                }
                out.append("## Final Prompt")
                out.append(prompt)
            }
            if let selection = obj["selection"]?.stringValue, !selection.isEmpty {
                if !out.isEmpty {
                    out.append("")
                }
                out.append("## Selection")
                out.append(selection)
            }

            var blocks: [MCP.Tool.Content] = out.isEmpty ? [] : [.text(out.joined(separator: "\n"))]

            // If plan/question was generated, format it using oracle_send formatter
            if let planObj = obj["plan"], case .object = planObj {
                // Use response_type to determine the heading
                let responseType = obj["response_type"]?.stringValue
                let heading = switch responseType {
                case "question":
                    "## Generated Answer"
                case "plan":
                    "## Generated Plan"
                default:
                    "## Generated Response"
                }
                let separator = blocks.isEmpty ? "" : "\n\n---\n\n"
                blocks.append(.text("\(separator)\(heading)\n"))
                let planBlocks = formatChatSend(args: [:], value: planObj, emitResources: false)
                blocks.append(contentsOf: planBlocks)
            }

            // If review was generated, format it using oracle_send formatter
            if let reviewObj = obj["review"], case .object = reviewObj {
                let separator = blocks.isEmpty ? "" : "\n\n---\n\n"
                blocks.append(.text("\(separator)## Code Review\n"))
                let reviewBlocks = formatChatSend(args: [:], value: reviewObj, emitResources: false)
                blocks.append(contentsOf: reviewBlocks)
            }

            // Follow-up hint
            if let hint = obj["follow_up_hint"]?.stringValue {
                let prefix = blocks.isEmpty ? "" : "\n\n"
                blocks.append(.text("\(prefix)> 💡 \(hint)"))
            }

            if let exportPath = obj["oracle_export_path"]?.stringValue,
               let handoffBlock = oracleExportBlock(
                   path: exportPath,
                   instruction: obj["oracle_export_instruction"]?.stringValue ?? AgentOracleExport.instruction(path: exportPath)
               )
            {
                let prefix = blocks.isEmpty ? "" : "\n\n"
                blocks.append(.text("\(prefix)\(handoffBlock)"))
            }

            return blocks
        }
        return formatGeneric(value: value)
    }

    static func formatFileAction(value: Value) -> [MCP.Tool.Content] {
        if let dto = value.decode(ToolResultDTOs.FileActionReply.self) {
            var out: [String] = []
            let ok = dto.status.lowercased() == "ok"
            out.append("## File Action \(statusIcon(success: ok))")
            out.append("- Action: \(dto.action)")
            out.append("- Path: `\(dto.path)`")
            if let np = dto.newPath { out.append("- New path: `\(np)`") }
            if dto.action.lowercased() == "delete" { out.append("- Result: Moved to macOS Trash") }
            if let warning = dto.warning, !warning.isEmpty { out.append("- Warning: \(warning)") }
            return [.text(out.joined(separator: "\n"))]
        }
        if case let .object(obj) = value {
            var out: [String] = []
            out.append("## File Action \(statusIcon(success: true))")
            let action = obj["action"]?.stringValue
            if let a = action { out.append("- Action: \(a)") }
            if let p = obj["path"]?.stringValue { out.append("- Path: `\(p)`") }
            if let np = obj["new_path"]?.stringValue { out.append("- New path: `\(np)`") }
            if action?.lowercased() == "delete" { out.append("- Result: Moved to macOS Trash") }
            if let st = obj["status"]?.stringValue { out.append("- Status: \(st)") }
            return [.text(out.joined(separator: "\n"))]
        }
        if let s = value.stringValue {
            return [.text("## File Action \(statusIcon(success: !s.isEmpty))\n\(s)")]
        }
        return formatGeneric(value: value)
    }

    // MARK: - Worktree Tool Formatter

    static func formatManageWorktree(args: [String: Value], value: Value) -> [MCP.Tool.Content] {
        guard let dto = value.decode(ToolResultDTOs.ManageWorktreeReplyDTO.self) else {
            return formatGeneric(value: value)
        }

        if let error = dto.error, !error.isEmpty {
            return [.text("## Manage Worktree \(dto.op.capitalized) ❌\n- **Error**: \(error)")]
        }
        if let merge = dto.merge {
            return formatManageWorktreeMerge(op: dto.op, dto: merge)
        }

        var out: [String] = []
        out.append("## Manage Worktree \(dto.op.capitalized) \(statusIcon(success: true))")
        if let repo = dto.repository {
            out.append("- **Repository**: \(repo.displayName) (`\(repo.repoKey)`)")
            out.append("- **Root**: `\(repo.rootPath)`")
            if let repositoryID = repo.repositoryID {
                out.append("- **Repository ID**: `\(repositoryID)`")
            }
        }

        switch dto.op.lowercased() {
        case "list":
            appendManageWorktreeList(&out, worktrees: dto.worktrees ?? [])
        case "show":
            if let worktree = dto.worktree ?? dto.worktrees?.first {
                appendManageWorktreeDetails(&out, worktree: worktree)
            }
        case "create":
            if let worktree = dto.createdWorktree ?? dto.worktree {
                out.append("")
                out.append("### Created")
                appendManageWorktreeDetails(&out, worktree: worktree)
                appendManageWorktreeNextSteps(&out, op: "create", worktree: worktree, binding: dto.binding)
            }
            appendManageWorktreeBinding(&out, title: "Binding", binding: dto.binding)
            appendManageWorktreeBinding(&out, title: "Previous Binding", binding: dto.previousBinding)
        case "bind", "select":
            if let worktree = dto.worktree ?? dto.worktrees?.first {
                out.append("")
                out.append("### Worktree")
                appendManageWorktreeDetails(&out, worktree: worktree)
            }
            appendManageWorktreeBinding(&out, title: "Binding", binding: dto.binding)
            appendManageWorktreeBinding(&out, title: "Previous Binding", binding: dto.previousBinding)
            if let worktree = dto.worktree ?? dto.worktrees?.first {
                appendManageWorktreeNextSteps(&out, op: dto.op.lowercased(), worktree: worktree, binding: dto.binding)
            }
        case "unbind":
            let removed = dto.bindings ?? dto.binding.map { [$0] } ?? []
            out.append("")
            out.append("### Removed Bindings")
            if removed.isEmpty {
                out.append("_None_")
            } else {
                for binding in removed {
                    out.append("- `\(binding.logicalRootName ?? binding.logicalRootPath)` → `\(binding.worktreeRootPath)` (`\(binding.worktreeID)`)")
                }
            }
        default:
            break
        }

        if let graph = dto.graph {
            out.append("")
            out.append("### Commit / Worktree Graph")
            var metadata = "_bounded to \(graph.limit) line\(graph.limit == 1 ? "" : "s")"
            if let source = graph.source, !source.isEmpty {
                metadata += " · `\(source)`"
            }
            metadata += "_"
            out.append(metadata)
            out.append("```text")
            out.append(contentsOf: graph.lines)
            out.append("```")
        }
        if let warning = dto.warning, !warning.isEmpty {
            out.append("")
            let lines = warning.components(separatedBy: .newlines).filter { !$0.isEmpty }
            for (index, line) in lines.enumerated() {
                out.append(index == 0 ? "> ⚠️ \(line)" : "> \(line)")
            }
        }
        return [.text(out.joined(separator: "\n"))]
    }

    private static func appendManageWorktreeList(
        _ out: inout [String],
        worktrees: [ToolResultDTOs.ManageWorktreeReplyDTO.WorktreeDTO]
    ) {
        out.append("")
        out.append("### Worktrees (\(worktrees.count))")
        guard !worktrees.isEmpty else {
            out.append("_No worktrees found._")
            return
        }
        for (index, worktree) in worktrees.enumerated() {
            let connector = index == worktrees.count - 1 ? "└─" : "├─"
            let marker = worktree.isMain ? "\(connector) main" : "\(connector) linked"
            var line = "\(marker) `\(worktree.worktreeID)`"
            if let branch = worktree.branch {
                line += " branch `\(branch)`"
            } else if worktree.isDetached {
                line += " detached"
            }
            if let label = worktree.visual?.label {
                line += " · \(label)"
            }
            if let color = worktree.visual?.colorHex {
                line += " · \(color)"
            }
            out.append(line)
            let childPrefix = index == worktrees.count - 1 ? "   " : "│  "
            out.append("\(childPrefix)path: `\(worktree.path)`")
            out.append("\(childPrefix)next: `manage_worktree {\"op\":\"show\",\"worktree_id\":\"\(worktree.worktreeID)\"}`")
            if let status = worktree.status {
                out.append("\(childPrefix)status: \(status.isDirty ? "dirty" : "clean") (\(status.staged) staged, \(status.modified) modified, \(status.untracked) untracked)")
            }
        }
    }

    private static func appendManageWorktreeDetails(
        _ out: inout [String],
        worktree: ToolResultDTOs.ManageWorktreeReplyDTO.WorktreeDTO
    ) {
        out.append("- **Worktree ID**: `\(worktree.worktreeID)`")
        out.append("- **Specifier**: `\(worktree.specifier)`")
        out.append("- **Path**: `\(worktree.path)`")
        if let branch = worktree.branch { out.append("- **Branch**: `\(branch)`") }
        if let head = worktree.head { out.append("- **HEAD**: `\(head)`") }
        out.append("- **Kind**: \(worktree.isMain ? "main" : "linked")\(worktree.isDetached ? " · detached" : "")")
        if worktree.isLocked { out.append("- **Locked**: \(worktree.lockReason ?? "yes")") }
        if worktree.isPrunable { out.append("- **Prunable**: \(worktree.prunableReason ?? "yes")") }
        if let visual = worktree.visual {
            out.append("- **Visual**: \(visual.label ?? "worktree") · \(visual.colorHex) · \(visual.iconName) · \(visual.markerStyle)")
        }
        if let status = worktree.status {
            out.append("- **Status**: \(status.isDirty ? "dirty" : "clean") (\(status.staged) staged, \(status.modified) modified, \(status.untracked) untracked)")
        }
    }

    private static func appendManageWorktreeNextSteps(
        _ out: inout [String],
        op: String,
        worktree: ToolResultDTOs.ManageWorktreeReplyDTO.WorktreeDTO,
        binding: ToolResultDTOs.ManageWorktreeReplyDTO.BindingDTO?
    ) {
        out.append("")
        out.append("### Next Steps")
        out.append("- Inspect: `manage_worktree {\"op\":\"show\",\"worktree_id\":\"\(worktree.worktreeID)\"}`")
        out.append("- List with graph: `manage_worktree {\"op\":\"list\",\"include_graph\":true,\"graph_limit\":24}`")
        if binding == nil {
            out.append("- Bind to an agent session: `manage_worktree {\"op\":\"bind\",\"worktree_id\":\"\(worktree.worktreeID)\",\"session_id\":\"<session_id>\"}`")
        }
        if op == "create" || binding != nil {
            out.append("- Start an agent here: `agent_run {\"op\":\"start\",\"worktree_id\":\"\(worktree.worktreeID)\",\"message\":\"<task>\"}`")
        }
    }

    private static func appendManageWorktreeBinding(
        _ out: inout [String],
        title: String,
        binding: ToolResultDTOs.ManageWorktreeReplyDTO.BindingDTO?
    ) {
        guard let binding else { return }
        out.append("")
        out.append("### \(title)")
        out.append("- **Logical root**: `\(binding.logicalRootName ?? binding.logicalRootPath)`")
        out.append("- **Worktree**: `\(binding.worktreeID)` at `\(binding.worktreeRootPath)`")
        if let branch = binding.branch { out.append("- **Branch**: `\(branch)`") }
        if let label = binding.visualLabel { out.append("- **Label**: \(label)") }
        if let color = binding.visualColorHex { out.append("- **Color**: \(color)") }
        out.append("- **Source**: \(binding.source)")
    }

    // MARK: - Worktree Merge Formatting

    private static func formatManageWorktreeMerge(
        op: String,
        dto: ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO
    ) -> [MCP.Tool.Content] {
        var out: [String] = []
        out.append("## Manage Worktree \(op.capitalized) \(worktreeMergeStatusIcon(dto.status))")
        out.append("")
        out.append("### Merge")
        out.append("- **Status**: `\(dto.status)`")
        if let operationID = dto.operationID { out.append("- **Operation ID**: `\(operationID)`") }
        if let sessionID = dto.sessionID { out.append("- **Session ID**: `\(sessionID)`") }

        if let source = dto.source, let target = dto.target {
            out.append("")
            out.append("### Endpoints")
            appendWorktreeMergeEndpoint(&out, title: "Source", endpoint: source)
            appendWorktreeMergeEndpoint(&out, title: "Target", endpoint: target)
        }

        if let visualization = dto.visualization {
            out.append("")
            out.append("### ASCII Visualization")
            out.append("_bounded to \(visualization.limit) line\(visualization.limit == 1 ? "" : "s")\(visualization.truncated ? ", truncated" : "")_")
            out.append("```text")
            if visualization.lines.isEmpty {
                out.append(visualization.text)
            } else {
                out.append(contentsOf: visualization.lines)
            }
            out.append("```")
        }

        if let preflight = dto.preflight {
            out.append("")
            out.append("### Preflight")
            out.append("- **Blocked**: \(preflight.blocked ? "yes" : "no")")
            if let prediction = preflight.conflictPrediction {
                var line = "- **Conflict prediction**: `\(prediction.status)`"
                if !prediction.files.isEmpty { line += " (\(prediction.files.count) file\(prediction.files.count == 1 ? "" : "s"))" }
                out.append(line)
                if let message = prediction.message, !message.isEmpty { out.append("  - \(message)") }
            }
            if !preflight.blockers.isEmpty {
                out.append("- **Blockers**:")
                for blocker in preflight.blockers {
                    var line = "  - `\(blocker.code)`: \(blocker.message)"
                    if !blocker.paths.isEmpty { line += " (\(blocker.paths.joined(separator: ", ")))" }
                    out.append(line)
                }
            }
        }

        if let summary = dto.summary {
            out.append("")
            out.append("### Summary")
            out.append("- **Commits**: \(summary.commits)")
            out.append("- **Files**: \(summary.files)")
            out.append("- **Changes**: +\(summary.insertions) -\(summary.deletions)")
        }

        let resultLines = worktreeMergeResultLines(dto)
        if !resultLines.isEmpty {
            out.append("")
            out.append("### Result")
            out.append(contentsOf: resultLines)
        }

        if let artifacts = dto.artifacts {
            out.append("")
            out.append("### Artifacts")
            out.append("- **Snapshot**: `\(artifacts.snapshotID)`")
            out.append("- **Directory**: `\(artifacts.snapshotDirectory)`")
            out.append("- **MAP**: `\(artifacts.mapPath)`")
            if let patch = artifacts.allPatchPath { out.append("- **Patch**: `\(patch)`") }
            out.append("- **Metadata**: `\(artifacts.sidecarPath)`")
        }

        if let conflictFiles = dto.conflictFiles, !conflictFiles.isEmpty {
            out.append("")
            out.append("### Conflicts")
            for path in conflictFiles {
                out.append("- `\(path)`")
            }
        }

        if let staleReason = dto.staleReason, !staleReason.isEmpty {
            out.append("")
            out.append("> ⚠️ Stale preview: \(staleReason)")
        }
        if let error = dto.error, !error.isEmpty {
            out.append("")
            out.append("> ❌ \(error)")
            if let errorCode = dto.errorCode { out.append("> error_code: `\(errorCode)`") }
        }
        if let postMerge = dto.postMerge {
            out.append("")
            out.append("### Post-merge")
            out.append("- **post_merge**: `\(postMerge)`")
            if let sourceWorktreeStatus = dto.sourceWorktreeStatus {
                out.append("- **source_worktree_status**: `\(sourceWorktreeStatus)`")
            }
        }
        if !dto.nextActions.isEmpty {
            out.append("")
            out.append("### Next Actions")
            for action in dto.nextActions {
                out.append("- \(action)")
            }
        }

        return [.text(out.joined(separator: "\n"))]
    }

    private static func appendWorktreeMergeEndpoint(
        _ out: inout [String],
        title: String,
        endpoint: ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO.EndpointDTO
    ) {
        var line = "- **\(title)**: \(endpoint.label) (`\(endpoint.worktreeID)`)"
        if let branch = endpoint.branch { line += " branch `\(branch)`" }
        line += " @ `\(endpoint.shortHead)`"
        out.append(line)
        out.append("  - path: `\(endpoint.path)`")
    }

    private static func worktreeMergeStatusIcon(_ status: String) -> String {
        switch status.lowercased() {
        case "preview", "completed", "aborted":
            statusIcon(success: true)
        case "blocked", "conflicted", "stale", "awaiting_approval", "applying", "awaiting_commit":
            "⚠️"
        default:
            "❌"
        }
    }

    private static func worktreeMergeResultLines(_ dto: ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO) -> [String] {
        var lines: [String] = []
        if let sourceHead = dto.sourceHead { lines.append("- **Source HEAD**: `\(sourceHead)`") }
        if let targetHeadBefore = dto.targetHeadBefore { lines.append("- **Target before**: `\(targetHeadBefore)`") }
        if let targetHeadAfter = dto.targetHeadAfter { lines.append("- **Target after**: `\(targetHeadAfter)`") }
        if let mergeCommit = dto.mergeCommit { lines.append("- **Merge commit**: `\(mergeCommit)`") }
        return lines
    }

    // MARK: - Git Tool Formatters

    static func formatGit(args: [String: Value], value: Value, emitResources: Bool) -> [MCP.Tool.Content] {
        guard let dto = value.decode(ToolResultDTOs.GitToolReplyDTO.self) else {
            return formatGeneric(value: value)
        }

        // Check for error first
        if let error = dto.error, !error.isEmpty {
            var out: [String] = []
            out.append("## Git \(dto.op.capitalized) ❌")
            out.append("- **Error**: \(error)")
            if let warning = dto.warning { out.append("- **Warning**: \(warning)") }
            return [.text(out.joined(separator: "\n"))]
        }

        let op = dto.op.lowercased()
        var blocks: [MCP.Tool.Content]

        // Check for multi-root response (repos array present or aggregate provided)
        let isMultiRoot = (dto.repos != nil) || (dto.aggregate != nil)

        switch op {
        case "status":
            if isMultiRoot {
                blocks = [.text(formatGitStatusMulti(dto))]
            } else {
                blocks = [.text(formatGitStatus(dto))]
            }
        case "diff":
            if isMultiRoot {
                blocks = formatGitDiffMulti(dto, emitResources: emitResources)
            } else {
                blocks = formatGitDiff(dto, emitResources: emitResources)
            }
        case "log":
            blocks = [.text(formatGitLog(dto))]
        case "show":
            blocks = formatGitShow(dto, emitResources: emitResources)
        case "blame":
            blocks = [.text(formatGitBlame(dto))]
        default:
            blocks = formatGeneric(value: value)
        }

        // Append common footer if present
        if let warning = dto.warning, !warning.isEmpty {
            blocks.append(.text("\n> ⚠️ **Warning**: \(warning)"))
        }
        if let emptyReason = dto.emptyReason, !emptyReason.isEmpty {
            blocks.append(.text("\n> ℹ️ **Empty result**: \(emptyReason)"))
        }

        return blocks
    }

    // MARK: Git Status

    private static func formatGitStatus(_ dto: ToolResultDTOs.GitToolReplyDTO) -> String {
        guard let status = dto.status else {
            return "## Git Status ⚠️\nNo status data available."
        }

        var out: [String] = []
        let hasChanges = !status.staged.isEmpty || !status.modified.isEmpty || !status.untracked.isEmpty
        out.append("## Git Status \(statusIcon(success: true))")

        if let worktree = dto.worktree, worktree.isWorktree {
            appendWorktreeInfo(&out, worktree: worktree)
        }

        // Branch info
        if let branch = status.branch {
            var branchLine = "**\(branch)**"
            if let upstream = status.upstream {
                branchLine += " → \(upstream)"
            }
            if let ahead = status.ahead, let behind = status.behind {
                if ahead > 0 || behind > 0 {
                    branchLine += " (+\(ahead) -\(behind))"
                }
            }
            out.append(branchLine)
        }

        out.append("")

        // Summary counts
        var counts: [String] = []
        if !status.staged.isEmpty { counts.append("\(status.staged.count) staged") }
        if !status.modified.isEmpty { counts.append("\(status.modified.count) modified") }
        if !status.untracked.isEmpty { counts.append("\(status.untracked.count) untracked") }
        if counts.isEmpty {
            out.append("_No changes_")
        } else {
            out.append(counts.joined(separator: " · "))
        }

        // File lists (compact format)
        if !status.staged.isEmpty {
            out.append("")
            out.append("### Staged")
            for file in status.staged.prefix(20) {
                out.append("• `\(file)`")
            }
            if status.staged.count > 20 {
                out.append("_...and \(status.staged.count - 20) more_")
            }
        }

        if !status.modified.isEmpty {
            out.append("")
            out.append("### Modified")
            for file in status.modified.prefix(20) {
                out.append("• `\(file)`")
            }
            if status.modified.count > 20 {
                out.append("_...and \(status.modified.count - 20) more_")
            }
        }

        if !status.untracked.isEmpty {
            out.append("")
            out.append("### Untracked")
            for file in status.untracked.prefix(20) {
                out.append("• `\(file)`")
            }
            if status.untracked.count > 20 {
                out.append("_...and \(status.untracked.count - 20) more_")
            }
        }

        return out.joined(separator: "\n")
    }

    // MARK: Git Status Multi-root

    private static func formatGitStatusMulti(_ dto: ToolResultDTOs.GitToolReplyDTO) -> String {
        guard let repos = dto.repos, !repos.isEmpty else {
            return "## Git Status \(statusIcon(success: true)) (0 repos)\nNo repo data available."
        }

        var out: [String] = []
        out.append("## Git Status \(statusIcon(success: true)) (\(repos.count) repos)")
        out.append("")

        for repo in repos {
            let repoName = repo.repoName ?? repo.repoKey
            out.append("### \(repoName)")
            out.append("`\(repo.repoRoot)`")

            if let worktree = repo.worktree, worktree.isWorktree {
                appendWorktreeInfo(&out, worktree: worktree)
            }

            if let error = repo.error {
                out.append("❌ Error: \(error)")
                out.append("")
                continue
            }

            if let status = repo.status {
                // Branch info
                if let branch = status.branch {
                    var branchLine = "**\(branch)**"
                    if let upstream = status.upstream {
                        branchLine += " → \(upstream)"
                    }
                    if let ahead = status.ahead, let behind = status.behind {
                        if ahead > 0 || behind > 0 {
                            branchLine += " (+\(ahead) -\(behind))"
                        }
                    }
                    out.append(branchLine)
                }

                // Summary counts
                var counts: [String] = []
                if !status.staged.isEmpty { counts.append("\(status.staged.count) staged") }
                if !status.modified.isEmpty { counts.append("\(status.modified.count) modified") }
                if !status.untracked.isEmpty { counts.append("\(status.untracked.count) untracked") }
                if counts.isEmpty {
                    out.append("_No changes_")
                } else {
                    out.append(counts.joined(separator: " · "))
                }
            } else {
                out.append("_No status data_")
            }
            out.append("")
        }

        return out.joined(separator: "\n")
    }

    // MARK: Git Diff

    private static func gitPerFilePatchSummary(_ patch: ToolResultDTOs.GitToolReplyDTO.PrimaryArtifactsDTO.PerFilePatchDTO) -> String? {
        var parts: [String] = []
        if let status = patch.status, !status.isEmpty {
            parts.append(status)
        }
        if let additions = patch.additions {
            parts.append("+\(additions)")
        }
        if let deletions = patch.deletions {
            parts.append("-\(deletions)")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }

    private static func gitPerFilePatchPreviewLines(
        patches: [ToolResultDTOs.GitToolReplyDTO.PrimaryArtifactsDTO.PerFilePatchDTO],
        limit: Int
    ) -> [String] {
        guard !patches.isEmpty else { return [] }
        let indexWidth = max(2, String(patches.map(\.jumpIndex).max() ?? 0).count)
        var lines: [String] = []
        lines.append("_Per-file patches below are selection-ready paths. They are not auto-selected, and you do not need to reconstruct the snapshot directory or `__` filename encoding._")
        for patch in patches.prefix(limit) {
            let idxText = String(format: "%0*d", indexWidth, patch.jumpIndex)
            let summarySuffix = gitPerFilePatchSummary(patch).map { " (\($0))" } ?? ""
            lines.append("- [\(idxText)] `\(patch.gitPath)`\(summarySuffix) → `\(patch.selectionPath)`")
        }
        if patches.count > limit {
            lines.append("- ...and \(patches.count - limit) more in `MAP.txt` under `SECTION: PER_FILE_PATCH_SELECTION_PATHS`")
        }
        return lines
    }

    private static func formatGitDiff(_ dto: ToolResultDTOs.GitToolReplyDTO, emitResources: Bool) -> [MCP.Tool.Content] {
        guard let diff = dto.diff else {
            return [.text("## Git Diff ⚠️\nNo diff data available.")]
        }

        var out: [String] = []
        out.append("## Git Diff \(statusIcon(success: true))")
        if let worktree = dto.worktree, worktree.isWorktree {
            appendWorktreeInfo(&out, worktree: worktree)
        }
        out.append("**Compare**: \(diff.compare)")

        // Totals
        let totals = diff.totals
        out.append("**\(totals.files) file\(totals.files == 1 ? "" : "s")** (+\(totals.insertions) -\(totals.deletions))")

        // By status breakdown
        if let byStatus = diff.byStatus, !byStatus.isEmpty {
            let statusParts = byStatus.sorted(by: { $0.key < $1.key }).map { "\($0.key):\($0.value)" }
            out.append("Status: \(statusParts.joined(separator: " "))")
        }

        // Truncation note
        if diff.truncated == true, let note = diff.truncationNote {
            out.append("")
            out.append("> ⚠️ \(note)")
        }

        // Files list
        let isFullDetail = diff.detail == "full"
        if let files = diff.files, !files.isEmpty {
            out.append("")
            out.append("### Files")

            let maxFilesToShow = isFullDetail ? Int.max : 30
            for file in files.prefix(maxFilesToShow) {
                let ins = file.insertions ?? 0
                let del = file.deletions ?? 0
                out.append("• `\(file.path)` \(file.status) +\(ins) -\(del)")
            }
            if files.count > maxFilesToShow {
                out.append("_...and \(files.count - maxFilesToShow) more files_")
            }

            // Hunks (if detail: patches or full)
            let filesWithHunks = files.filter { $0.hunks != nil && !($0.hunks?.isEmpty ?? true) }
            if !filesWithHunks.isEmpty {
                out.append("")
                out.append("### Patches")

                // detail="full" lifts formatter caps; detail="patches" keeps them
                let maxFilesWithPatches = isFullDetail ? Int.max : 10
                let maxHunksPerFile = isFullDetail ? Int.max : 5
                for file in filesWithHunks.prefix(maxFilesWithPatches) {
                    guard let hunks = file.hunks, !hunks.isEmpty else { continue }
                    out.append("")
                    out.append("#### `\(file.path)`")
                    out.append("```diff")
                    for hunk in hunks.prefix(maxHunksPerFile) {
                        out.append(hunk.header)
                        out.append(hunk.patch)
                    }
                    if hunks.count > maxHunksPerFile {
                        out.append("... [\(hunks.count - maxHunksPerFile) more hunks]")
                    }
                    out.append("```")
                }
                if filesWithHunks.count > maxFilesWithPatches {
                    out.append("")
                    out.append("_Omitted patches for \(filesWithHunks.count - maxFilesWithPatches) more files_")
                }
            }
        }

        var blocks: [MCP.Tool.Content] = [.text(out.joined(separator: "\n"))]

        // Artifacts section (when artifacts: true was used)
        if let snapshotId = dto.snapshotId {
            var artifactOut: [String] = []
            artifactOut.append("")
            artifactOut.append("### Snapshot")
            artifactOut.append("- **ID**: `\(snapshotId)`")
            // Include _git_data/ prefix so agents can construct full paths
            let gitDataDir = dto.snapshotDir.map { "_git_data/\($0)" }
            if let dir = gitDataDir {
                artifactOut.append("- **Dir**: `\(dir)`")
            }

            if let modeDetails = dto.modeDetails {
                artifactOut.append("- **Mode**: \(modeDetails)")
            }

            // Artifacts list with full selectable paths
            if let artifacts = dto.artifacts, let baseDir = gitDataDir {
                artifactOut.append("")
                artifactOut.append("**Artifacts**:")
                if let allPatch = artifacts.allPatch {
                    artifactOut.append("- all.patch: `\(baseDir)/\(allPatch)`")
                }
                if let perFilePatches = dto.primaryArtifacts?.perFilePatches, !perFilePatches.isEmpty {
                    artifactOut.append("- per-file: `\(baseDir)/diff/per-file/`")
                }
                artifactOut.append("- map: `\(baseDir)/\(artifacts.map)`")
            }
            if let primary = dto.primaryArtifacts {
                artifactOut.append("")
                artifactOut.append("**Primary review artifacts (auto-selected when possible):**")
                let autoSelected = Set(primary.autoSelected ?? [])
                let mapSuffix = autoSelected.contains(primary.map) ? " (auto-selected)" : ""
                artifactOut.append("- MAP.txt: `\(primary.map)`\(mapSuffix)")
                if let allPatch = primary.allPatch {
                    let allPatchSuffix = autoSelected.contains(allPatch) ? " (auto-selected)" : ""
                    artifactOut.append("- all.patch: `\(allPatch)`\(allPatchSuffix)")
                }
                if let perFilePatches = primary.perFilePatches, !perFilePatches.isEmpty {
                    artifactOut.append("")
                    artifactOut.append(contentsOf: gitPerFilePatchPreviewLines(patches: perFilePatches, limit: 10))
                }
            }

            blocks.append(.text(artifactOut.joined(separator: "\n")))

            // Inline map excerpt
            if let inline = dto.inline, !inline.mapExcerpt.isEmpty {
                var inlineOut: [String] = []
                inlineOut.append("")
                inlineOut.append("### MAP Excerpt")
                if inline.truncated {
                    inlineOut.append("_Showing \(inline.returnedLines) of \(inline.totalLines) lines_")
                }
                inlineOut.append("```text")
                inlineOut.append(inline.mapExcerpt)
                inlineOut.append("```")
                blocks.append(.text(inlineOut.joined(separator: "\n")))
            }
        }

        return blocks
    }

    // MARK: Git Diff Multi-root

    private static func formatGitDiffMulti(_ dto: ToolResultDTOs.GitToolReplyDTO, emitResources: Bool) -> [MCP.Tool.Content] {
        guard let repos = dto.repos, !repos.isEmpty else {
            return [.text("## Git Diff \(statusIcon(success: true)) (0 repos)\nNo repo data available.")]
        }

        var out: [String] = []

        // Aggregate header
        if let aggregate = dto.aggregate {
            let repoCount = aggregate.repoCount ?? repos.count
            out.append("## Git Diff \(statusIcon(success: true)) (\(repoCount) repos)")

            if let totals = aggregate.totals {
                out.append("**Total: \(totals.files) file\(totals.files == 1 ? "" : "s")** (+\(totals.insertions) -\(totals.deletions))")
            }
            if let byStatus = aggregate.byStatus, !byStatus.isEmpty {
                let statusParts = byStatus.sorted(by: { $0.key < $1.key }).map { "\($0.key):\($0.value)" }
                out.append("Status: \(statusParts.joined(separator: " "))")
            }
            if let oneliner = aggregate.oneliner {
                out.append("_\(oneliner)_")
            }
        } else {
            out.append("## Git Diff \(statusIcon(success: true)) (\(repos.count) repos)")
        }

        out.append("")

        // Per-repo sections
        for repo in repos {
            let repoName = repo.repoName ?? repo.repoKey
            out.append("### \(repoName)")
            out.append("`\(repo.repoRoot)`")

            if let worktree = repo.worktree, worktree.isWorktree {
                appendWorktreeInfo(&out, worktree: worktree)
            }

            if let error = repo.error {
                out.append("❌ Error: \(error)")
                out.append("")
                continue
            }

            if let diff = repo.diff {
                out.append("**Compare**: \(diff.compare)")
                let totals = diff.totals
                out.append("**\(totals.files) file\(totals.files == 1 ? "" : "s")** (+\(totals.insertions) -\(totals.deletions))")

                if let byStatus = diff.byStatus, !byStatus.isEmpty {
                    let statusParts = byStatus.sorted(by: { $0.key < $1.key }).map { "\($0.key):\($0.value)" }
                    out.append("Status: \(statusParts.joined(separator: " "))")
                }

                // Files list (compact for multi-root)
                if let files = diff.files, !files.isEmpty {
                    let maxFilesToShow = 15
                    for file in files.prefix(maxFilesToShow) {
                        let ins = file.insertions ?? 0
                        let del = file.deletions ?? 0
                        out.append("• `\(file.path)` \(file.status) +\(ins) -\(del)")
                    }
                    if files.count > maxFilesToShow {
                        out.append("_...and \(files.count - maxFilesToShow) more files_")
                    }
                }
            }

            // Snapshot/artifacts info
            if let snapshotId = repo.snapshotId {
                out.append("")
                out.append("**Snapshot**: `\(snapshotId)`")
                // Include _git_data/ prefix so agents can construct full paths
                let gitDataDir = repo.snapshotDir.map { "_git_data/\($0)" }
                if let dir = gitDataDir {
                    out.append("**Dir**: `\(dir)`")
                }
                // Show key artifact paths for selection
                if let artifacts = repo.artifacts, let baseDir = gitDataDir {
                    out.append("**Artifacts** (use with `manage_selection`):")
                    out.append("- map: `\(baseDir)/\(artifacts.map)`")
                    if let allPatch = artifacts.allPatch {
                        out.append("- all.patch: `\(baseDir)/\(allPatch)`")
                    }
                    if let perFilePatches = repo.primaryArtifacts?.perFilePatches, !perFilePatches.isEmpty {
                        out.append("- per-file: `\(baseDir)/diff/per-file/`")
                    }
                }
                if let primary = repo.primaryArtifacts {
                    out.append("**Primary review artifacts**:")
                    let autoSelected = Set(primary.autoSelected ?? [])
                    let mapSuffix = autoSelected.contains(primary.map) ? " (auto-selected)" : ""
                    out.append("- MAP.txt: `\(primary.map)`\(mapSuffix)")
                    if let allPatch = primary.allPatch {
                        let allPatchSuffix = autoSelected.contains(allPatch) ? " (auto-selected)" : ""
                        out.append("- all.patch: `\(allPatch)`\(allPatchSuffix)")
                    }
                    if let perFilePatches = primary.perFilePatches, !perFilePatches.isEmpty {
                        out.append(contentsOf: gitPerFilePatchPreviewLines(patches: perFilePatches, limit: 5))
                    }
                }
            }

            // Inline map excerpt (abbreviated for multi-root)
            if let inline = repo.inline, !inline.mapExcerpt.isEmpty {
                let excerpt = inline.mapExcerpt
                out.append("")
                out.append("**MAP excerpt** (\(inline.returnedLines)/\(inline.totalLines) lines):")
                out.append("```")
                // Show first 20 lines for multi-root
                let lines = excerpt.components(separatedBy: "\n")
                for line in lines.prefix(20) {
                    out.append(line)
                }
                if lines.count > 20 {
                    out.append("... [\(lines.count - 20) more lines]")
                }
                out.append("```")
            }

            if let emptyReason = repo.emptyReason {
                out.append("_Empty: \(emptyReason)_")
            }

            out.append("")
        }

        return [.text(out.joined(separator: "\n"))]
    }

    private static func appendWorktreeInfo(_ out: inout [String], worktree: ToolResultDTOs.GitToolReplyDTO.WorktreeDTO) {
        var label = "**Worktree**"
        if let name = worktree.worktreeName, !name.isEmpty {
            label += " `\(name)`"
        }
        let branch = worktree.worktreeBranch ?? "detached"
        let head = worktree.worktreeHead.map { "@\($0)" } ?? ""
        out.append("\(label): \(branch)\(head)")
        if let mainRoot = worktree.mainWorktreeRoot {
            var mainLine = "Main checkout: `\(mainRoot)`"
            if let mainBranch = worktree.mainBranch {
                let mainHead = worktree.mainHead.map { "@\($0)" } ?? ""
                mainLine += " (\(mainBranch)\(mainHead))"
            }
            out.append(mainLine)
        }
        out.append("")
    }

    // MARK: Git Log

    private static func formatGitLog(_ dto: ToolResultDTOs.GitToolReplyDTO) -> String {
        guard let log = dto.log else {
            return "## Git Log ⚠️\nNo log data available."
        }

        var out: [String] = []
        out.append("## Git Log \(statusIcon(success: true))")
        if let worktree = dto.worktree, worktree.isWorktree {
            appendWorktreeInfo(&out, worktree: worktree)
        }
        out.append("**\(log.commits.count) commit\(log.commits.count == 1 ? "" : "s")**")
        out.append("")

        for commit in log.commits {
            let stats = "+\(commit.insertions) -\(commit.deletions)"
            let files = "\(commit.filesChanged) file\(commit.filesChanged == 1 ? "" : "s")"
            // Truncate long messages
            let msg = commit.message.count > 72 ? String(commit.message.prefix(69)) + "..." : commit.message
            out.append("• `\(commit.shortSha)` \(msg)")
            out.append("  _\(commit.author), \(formatGitDate(commit.date))_ — \(files) \(stats)")
        }

        return out.joined(separator: "\n")
    }

    // MARK: Git Show

    private static func formatGitShow(_ dto: ToolResultDTOs.GitToolReplyDTO, emitResources: Bool) -> [MCP.Tool.Content] {
        guard let show = dto.show else {
            return [.text("## Git Show ⚠️\nNo commit data available.")]
        }

        var out: [String] = []
        out.append("## Git Show \(statusIcon(success: true))")
        if let worktree = dto.worktree, worktree.isWorktree {
            appendWorktreeInfo(&out, worktree: worktree)
        }
        out.append("**Commit**: `\(show.sha)`")
        out.append("**Author**: \(show.author)")
        out.append("**Date**: \(formatGitDate(show.date))")
        out.append("")

        // Message
        let messageLines = show.message.components(separatedBy: "\n")
        if messageLines.count == 1 {
            out.append("**Message**: \(show.message)")
        } else {
            out.append("**Message**:")
            out.append("```text")
            out.append(show.message)
            out.append("```")
        }

        // Totals
        let totals = show.totals
        out.append("")
        out.append("**\(totals.files) file\(totals.files == 1 ? "" : "s")** (+\(totals.insertions) -\(totals.deletions))")

        // Files
        if let files = show.files, !files.isEmpty {
            out.append("")
            out.append("### Files")
            for file in files.prefix(30) {
                let ins = file.insertions ?? 0
                let del = file.deletions ?? 0
                out.append("• `\(file.path)` \(file.status) +\(ins) -\(del)")
            }
            if files.count > 30 {
                out.append("_...and \(files.count - 30) more_")
            }
        }

        // Hunks
        if let hunks = show.hunks, !hunks.isEmpty {
            out.append("")
            out.append("### Diff")
            out.append("```diff")
            for hunk in hunks.prefix(10) {
                out.append(hunk.header)
                out.append(hunk.patch)
            }
            if hunks.count > 10 {
                out.append("... [\(hunks.count - 10) more hunks]")
            }
            out.append("```")
        }

        return [.text(out.joined(separator: "\n"))]
    }

    // MARK: Git Blame

    private static func formatGitBlame(_ dto: ToolResultDTOs.GitToolReplyDTO) -> String {
        guard let blame = dto.blame else {
            return "## Git Blame ⚠️\nNo blame data available."
        }

        var out: [String] = []
        out.append("## Git Blame \(statusIcon(success: true))")
        if let worktree = dto.worktree, worktree.isWorktree {
            appendWorktreeInfo(&out, worktree: worktree)
        }
        out.append("**Path**: `\(blame.path)`")
        out.append("**Lines**: \(blame.lines.count)")
        out.append("")

        // Render as a table-like format
        out.append("```")
        for line in blame.lines.prefix(100) {
            let lineNum = String(format: "%4d", line.num)
            let sha = line.sha.prefix(7)
            let author = String(line.author.prefix(12)).padding(toLength: 12, withPad: " ", startingAt: 0)
            let date = formatGitDateShort(line.date)
            let content = truncateSnippetLine(line.content, limit: 80)
            out.append("\(lineNum) │ \(sha) │ \(author) │ \(date) │ \(content)")
        }
        if blame.lines.count > 100 {
            out.append("... [\(blame.lines.count - 100) more lines]")
        }
        out.append("```")

        return out.joined(separator: "\n")
    }

    // MARK: Git Date Helpers

    private static func formatGitDate(_ isoDate: String) -> String {
        // Try to parse ISO8601 and format nicely, fallback to raw string
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoDate) {
            let display = DateFormatter()
            display.dateStyle = .medium
            display.timeStyle = .short
            return display.string(from: date)
        }
        // Try without fractional seconds
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: isoDate) {
            let display = DateFormatter()
            display.dateStyle = .medium
            display.timeStyle = .short
            return display.string(from: date)
        }
        return isoDate
    }

    private static func formatGitDateShort(_ isoDate: String) -> String {
        // Short date only (for blame)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoDate) {
            let display = DateFormatter()
            display.dateFormat = "yyyy-MM-dd"
            return display.string(from: date)
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: isoDate) {
            let display = DateFormatter()
            display.dateFormat = "yyyy-MM-dd"
            return display.string(from: date)
        }
        // Fallback: try to extract just the date part
        if isoDate.count >= 10 {
            return String(isoDate.prefix(10))
        }
        return isoDate
    }

    static func formatSearch(value: Value) -> [MCP.Tool.Content] {
        if let dto = value.decode(ToolResultDTOs.SearchResultDTO.self) {
            if let error = dto.errorMessage, !error.isEmpty {
                return [.text(searchErrorResults(dto: dto, error: error))]
            }
            let text = searchResults(dto: dto)
            return [.text(text)]
        }
        if let s = value.stringValue {
            // Legacy plain text
            return [.text("## Search Results \(statusIcon(success: !s.isEmpty))\n\(s)")]
        }
        return formatGeneric(value: value)
    }

    private static func matchSnippetLines(for group: ToolResultDTOs.SearchResultDTO.ContentMatchGroup, adjacency: Int = 2) -> [String] {
        struct LineInfo {
            let text: String
            let isMatch: Bool
        }
        struct Segment {
            var start: Int
            var end: Int
            var lines: [Int: LineInfo]
        }

        var segments: [Segment] = []
        var matchFrequency: [Int: Int] = [:]

        for match in group.lines {
            var lineEntries: [Int: LineInfo] = [:]
            var minLine = match.lineNumber
            var maxLine = match.lineNumber

            if let before = match.contextBefore {
                for ctx in before {
                    lineEntries[ctx.lineNumber] = LineInfo(text: ctx.lineText, isMatch: false)
                    minLine = min(minLine, ctx.lineNumber)
                    maxLine = max(maxLine, ctx.lineNumber)
                }
            }

            lineEntries[match.lineNumber] = LineInfo(text: match.lineText, isMatch: true)
            matchFrequency[match.lineNumber, default: 0] += 1
            minLine = min(minLine, match.lineNumber)
            maxLine = max(maxLine, match.lineNumber)

            if let after = match.contextAfter {
                for ctx in after {
                    lineEntries[ctx.lineNumber] = LineInfo(text: ctx.lineText, isMatch: false)
                    minLine = min(minLine, ctx.lineNumber)
                    maxLine = max(maxLine, ctx.lineNumber)
                }
            }

            segments.append(Segment(start: minLine, end: maxLine, lines: lineEntries))
        }

        segments.sort { $0.start < $1.start }
        var merged: [Segment] = []
        for seg in segments {
            if var last = merged.popLast() {
                if seg.start <= last.end + adjacency {
                    last.start = min(last.start, seg.start)
                    last.end = max(last.end, seg.end)
                    for (lineNumber, info) in seg.lines {
                        if let existing = last.lines[lineNumber] {
                            last.lines[lineNumber] = LineInfo(text: existing.text, isMatch: existing.isMatch || info.isMatch)
                        } else {
                            last.lines[lineNumber] = info
                        }
                    }
                    merged.append(last)
                } else {
                    merged.append(last)
                    merged.append(seg)
                }
            } else {
                merged.append(seg)
            }
        }

        var block: [String] = []
        for (index, segment) in merged.enumerated() {
            if index > 0 { block.append("") }
            let ordered = segment.lines.keys.sorted()
            var previousLine: Int?
            for lineNumber in ordered {
                if let previousLine, lineNumber > previousLine + 1 {
                    block.append(renderSnippetGapLine())
                }
                guard let info = segment.lines[lineNumber] else { continue }
                if info.isMatch {
                    let occurrences = max(1, matchFrequency[lineNumber] ?? 1)
                    block.append(renderSnippetLine(number: lineNumber, text: info.text, marker: "▶ ", occurrences: occurrences))
                } else {
                    block.append(renderSnippetLine(number: lineNumber, text: info.text, marker: "  "))
                }
                previousLine = lineNumber
            }
        }
        return block
    }

    private static func renderMatchSnippet(for group: ToolResultDTOs.SearchResultDTO.ContentMatchGroup, adjacency: Int = 2) -> String {
        let inner = matchSnippetLines(for: group, adjacency: adjacency)
        return (["```text"] + inner + ["```"]).joined(separator: "\n")
    }

    private static func renderSnippetLine(number: Int, text: String, marker: String, occurrences: Int = 1) -> String {
        let locale = Locale(identifier: "en_US_POSIX")
        let paddedNumber = String(format: "%5d", locale: locale, number)
        let clipped = truncateSnippetLine(text)
        let suffix = occurrences > 1 ? " ×\(occurrences)" : ""
        return "\(paddedNumber) │ \(marker)\(clipped)\(suffix)"
    }

    private static func renderSnippetGapLine() -> String {
        let pad = String(repeating: " ", count: 5)
        return "\(pad) │   ⋮"
    }

    private static func truncateSnippetLine(_ text: String, limit: Int = 160) -> String {
        guard text.count > limit else { return text }
        let endIndex = text.index(text.startIndex, offsetBy: limit - 1)
        let prefix = String(text[text.startIndex ..< endIndex])
        return prefix + "…"
    }

    /// Fallback: present Value as a single fenced JSON block.
    static func formatGeneric(value: Value) -> [MCP.Tool.Content] {
        let json = prettyJSON(value)
        return [.text("```json\n\(json)\n```")]
    }

    static func formatAgentRun(args: [String: Value], value: Value) -> [MCP.Tool.Content] {
        formatAgentControlRun(
            args: args,
            value: value,
            title: "Agent run",
            operationFallback: "run",
            multiPollTitle: "Agent run · Poll (multiple)",
            supportsRespondGuidance: true
        )
    }

    static func formatAgentExplore(args: [String: Value], value: Value) -> [MCP.Tool.Content] {
        formatAgentControlRun(
            args: args,
            value: value,
            title: "Agent explore",
            operationFallback: "explore",
            multiPollTitle: "Agent explore · Poll (multiple)",
            multiStartTitle: "Agent explore · Start (multiple)",
            supportsRespondGuidance: false
        )
    }

    private static func formatAgentControlRun(
        args: [String: Value],
        value: Value,
        title: String,
        operationFallback: String,
        multiPollTitle: String,
        multiStartTitle: String? = nil,
        supportsRespondGuidance: Bool
    ) -> [MCP.Tool.Content] {
        guard let object = value.objectValue else {
            return formatGeneric(value: value)
        }
        // Multi-start collection response
        if let multiStartTitle,
           let startMeta = object["start"]?.objectValue,
           startMeta["mode"]?.stringValue == "many"
        {
            return formatMultiStart(object: object, startMeta: startMeta, title: multiStartTitle)
        }
        // Multi-poll collection response
        if let pollMeta = object["poll"]?.objectValue, pollMeta["mode"]?.stringValue == "many" {
            return formatMultiPoll(object: object, pollMeta: pollMeta, title: multiPollTitle)
        }
        let op = prettifiedAgentControlOperation(args["op"]?.stringValue, fallback: operationFallback)
        let session = object["session"]?.objectValue
        let agent = object["agent"]?.objectValue
        let interaction = object["interaction"]?.objectValue
        let meta = object["_meta"]?.objectValue
        let sessionID = object["session_id"]?.stringValue ?? session?["id"]?.stringValue
        let status = prettifiedAgentStatus(object["status"]?.stringValue)
        let statusText = object["status_text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionName = session?["name"]?.stringValue
        let agentName = agent?["name"]?.stringValue ?? agent?["id"]?.stringValue
        let model = agent?["model"]?.stringValue
        let reasoning = agent?["reasoning_effort"]?.stringValue
        let assistantText = object["assistant_text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isTerminal: Bool = {
            guard let raw = object["status"]?.stringValue else { return false }
            return ["completed", "failed", "cancelled", "expired"].contains(raw)
        }()
        let interactionKind = prettifiedAgentStatus(interaction?["kind"]?.stringValue)
        let interactionPrompt = interaction?["prompt"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let delivery = humanizedAgentDelivery(meta?["delivery"]?.stringValue)
        let failureReason = object["failure_reason"]?.stringValue
        let workflowName = object["workflow_name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let workflowID = object["workflow_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let worktrees = agentRunWorktreeObjects(from: object)

        var lines = ["**\(title) · \(op)**"]
        if let status {
            lines.append("- Status: **\(status)**")
        }
        if let failureReason, !failureReason.isEmpty {
            lines.append("- Failure reason: `\(failureReason)`")
        }
        if let workflowName, !workflowName.isEmpty {
            if let workflowID, !workflowID.isEmpty, workflowID != workflowName {
                lines.append("- Workflow: `\(workflowName)` (`\(workflowID)`)")
            } else {
                lines.append("- Workflow: `\(workflowName)`")
            }
        } else if let workflowID, !workflowID.isEmpty {
            lines.append("- Workflow: `\(workflowID)`")
        }
        if let statusText, !statusText.isEmpty {
            lines.append("- Note: \(statusText)")
        }
        if let sessionName, !sessionName.isEmpty {
            lines.append("- Session: `\(sessionName)`")
        }
        if let sessionID, !sessionID.isEmpty {
            lines.append("- Session ID: `\(sessionID)`")
        }
        lines.append(contentsOf: formattedAgentRunWorktreeLines(worktrees))
        // Multi-wait metadata
        let waitMeta = object["wait"]?.objectValue
        if let waitMeta, waitMeta["mode"]?.stringValue == "any" {
            let waitResult = waitMeta["result"]?.stringValue ?? ""
            let waitedCount = waitMeta["waited_count"]?.intValue
            let winnerSessionID = waitMeta["winner_session_id"]?.stringValue
            let pendingIDs = waitMeta["pending_session_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let countText = waitedCount.map(String.init) ?? "multiple"
            lines.append("- Wait: first-of-\(countText) sessions")
            switch waitResult {
            case "snapshot_ready":
                lines.append("- Result: **winner ready**")
            case "timed_out":
                lines.append("- Result: **timed out** (no session reached interesting state)")
            case "expired":
                lines.append("- Result: **session expired**")
            default:
                lines.append("- Result: `\(waitResult)`")
            }
            if let winnerSessionID, !winnerSessionID.isEmpty {
                lines.append("- Winner: `\(winnerSessionID)`")
            }
            if !pendingIDs.isEmpty {
                lines.append("- Pending: \(pendingIDs.map { "`\($0)`" }.joined(separator: ", "))")
            }
        }
        if let agentName, !agentName.isEmpty {
            var agentLine = "- Agent: **\(agentName)**"
            if let model, !model.isEmpty {
                agentLine += " · `\(model)`"
            }
            if let reasoning, !reasoning.isEmpty {
                agentLine += " · reasoning `\(reasoning)`"
            }
            lines.append(agentLine)
        }
        if let interactionKind, !interactionKind.isEmpty {
            lines.append("- Interaction: **\(interactionKind)**")
        }
        let interactionID = object["interaction_id"]?.stringValue ?? interaction?["id"]?.stringValue
        if let interactionID, !interactionID.isEmpty {
            lines.append("- Interaction ID: `\(interactionID)`")
        }
        if let delivery {
            lines.append("- Delivery: \(delivery)")
        }
        if object["status"]?.stringValue == "waiting_for_input",
           let interactionID, !interactionID.isEmpty,
           let sessionID, !sessionID.isEmpty
        {
            lines.append("")
            if supportsRespondGuidance {
                let kindRaw = interaction?["kind"]?.stringValue ?? ""
                lines.append("### How to respond")
                lines.append("Use `agent_run` with `op=respond`, `session_id=\"\(sessionID)\"`, and `interaction_id=\"\(interactionID)\"`.")
                switch kindRaw {
                case "instruction":
                    lines.append("- Provide `response=\"<your instruction text>\"`")
                    lines.append("- **Important**: Use `respond`, not `steer`, while status is `waiting_for_input`.")
                case "question":
                    let options = interaction?["options"]?.arrayValue ?? []
                    if !options.isEmpty {
                        let labels = options.compactMap { $0.objectValue?["label"]?.stringValue }
                        lines.append("- Allowed choices: \(labels.map { "`\($0)`" }.joined(separator: ", "))")
                    }
                    lines.append("- Provide `response=\"<answer>\"` or `response=\"skip\"` to skip.")
                case "approval":
                    let options = interaction?["options"]?.arrayValue ?? []
                    if !options.isEmpty {
                        let labels = options.compactMap { $0.objectValue?["label"]?.stringValue }
                        lines.append("- Allowed decisions: \(labels.map { "`\($0)`" }.joined(separator: ", "))")
                    } else {
                        lines.append("- Allowed decisions: `accept`, `accept_for_session`, `accept_with_amendment`, `decline`, `cancel`")
                    }
                    lines.append("- For `accept_with_amendment`, also provide `amendment=\"<text>\"`.")
                case "user_input":
                    let fields = interaction?["fields"]?.arrayValue ?? []
                    if fields.count == 1 {
                        lines.append("- Provide `response=\"<value>\"` as a shorthand for a single field.")
                    } else if !fields.isEmpty {
                        lines.append("- Provide `answers` object keyed by field id:")
                        for field in fields {
                            guard let f = field.objectValue, let fid = f["id"]?.stringValue else { continue }
                            let prompt = f["prompt"]?.stringValue ?? ""
                            lines.append("  - `\(fid)`: \(prompt)")
                        }
                    }
                default:
                    lines.append("- Provide `response=\"<your response>\"`")
                }
            } else {
                lines.append("### Waiting for input")
                lines.append("agent_explore does not support respond. Cancel this explore run or start a new explore run with clearer instructions.")
            }
        }
        if let interactionPrompt, !interactionPrompt.isEmpty {
            lines.append("\n**Prompt**\n\n\(interactionPrompt)")
        }
        if let assistantText, !assistantText.isEmpty {
            let heading = isTerminal ? "Output" : "Preview"
            lines.append("\n**\(heading)**\n\n\(assistantText)")
        }
        return [.text(lines.joined(separator: "\n"))]
    }

    private static func agentRunWorktreeObjects(from object: [String: Value]) -> [[String: Value]] {
        if let bindings = object["worktree_bindings"]?.arrayValue {
            let objects = bindings.compactMap(\.objectValue)
            if !objects.isEmpty { return objects }
        }
        if let worktree = object["worktree"]?.objectValue {
            return [worktree]
        }
        return []
    }

    private static func formattedAgentRunWorktreeLines(_ worktrees: [[String: Value]]) -> [String] {
        guard !worktrees.isEmpty else { return [] }
        if worktrees.count == 1, let line = formattedAgentRunWorktreeLine(worktrees[0], includeLogicalRoot: false) {
            return [line]
        }
        return worktrees.compactMap { formattedAgentRunWorktreeLine($0, includeLogicalRoot: true) }
    }

    private static func formattedAgentRunWorktreeLine(_ worktree: [String: Value], includeLogicalRoot: Bool) -> String? {
        let label = worktree["visual_label"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = worktree["worktree_name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = worktree["branch"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let worktreeID = worktree["worktree_id"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = worktree["worktree_root_path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let color = worktree["visual_color_hex"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let logicalRoot = worktree["logical_root_name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? worktree["logical_root_path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let unavailable = worktree["unavailable"]?.boolValue == true
        let title = [label, name, branch, worktreeID].compactMap { value in
            value?.isEmpty == false ? value : nil
        }.first ?? "bound worktree"
        var components = ["- Worktree: **\(title)**"]
        if includeLogicalRoot, let logicalRoot, !logicalRoot.isEmpty {
            components.append("root `\(logicalRoot)`")
        }
        if let branch, !branch.isEmpty, branch != title {
            components.append("branch `\(branch)`")
        }
        if let worktreeID, !worktreeID.isEmpty {
            components.append("`\(worktreeID)`")
        }
        if let color, !color.isEmpty {
            components.append(color)
        }
        if let path, !path.isEmpty {
            components.append("path `\(path)`")
        }
        if unavailable {
            components.append("⚠️ unavailable")
        }
        return components.joined(separator: " · ")
    }

    private static func formatMultiStart(object: [String: Value], startMeta: [String: Value], title: String) -> [MCP.Tool.Content] {
        var lines = ["**\(title)**"]
        let startedCount = startMeta["started_count"]?.intValue ?? object["session_ids"]?.arrayValue?.count ?? 0
        let result = startMeta["result"]?.stringValue ?? ""
        let runningIDs = startMeta["running_session_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let terminalIDs = startMeta["terminal_session_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let interestingIDs = startMeta["interesting_session_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
        lines.append("- Sessions started: \(startedCount)")
        if !result.isEmpty {
            lines.append("- Result: **\(prettifiedAgentStatus(result) ?? result)**")
        }
        lines.append("- Running: \(runningIDs.count)")
        if !terminalIDs.isEmpty {
            lines.append("- Terminal: \(terminalIDs.count)")
        }
        if !interestingIDs.isEmpty {
            lines.append("- Interesting: \(interestingIDs.count)")
        }
        let snapshots = object["snapshots"]?.arrayValue ?? []
        for snap in snapshots {
            guard let snapObj = snap.objectValue else { continue }
            let sid = snapObj["session_id"]?.stringValue ?? "?"
            let status = prettifiedAgentStatus(snapObj["status"]?.stringValue) ?? "unknown"
            let name = snapObj["session"]?.objectValue?["name"]?.stringValue
            var line = "- `\(sid)` — **\(status)**"
            if let name, !name.isEmpty {
                line += " (\(name))"
            }
            lines.append(line)
        }
        return [.text(lines.joined(separator: "\n"))]
    }

    private static func formatMultiPoll(object: [String: Value], pollMeta: [String: Value], title: String) -> [MCP.Tool.Content] {
        var lines = ["**\(title)**"]
        let polledCount = pollMeta["polled_count"]?.intValue ?? 0
        let interestingIDs = pollMeta["interesting_session_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let runningIDs = pollMeta["running_session_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let terminalIDs = pollMeta["terminal_session_ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
        lines.append("- Sessions polled: \(polledCount)")
        if !interestingIDs.isEmpty {
            lines.append("- Interesting: \(interestingIDs.count)")
        }
        if !runningIDs.isEmpty {
            lines.append("- Running: \(runningIDs.count)")
        }
        if !terminalIDs.isEmpty {
            lines.append("- Terminal: \(terminalIDs.count)")
        }
        let snapshots = object["snapshots"]?.arrayValue ?? []
        for snap in snapshots {
            guard let snapObj = snap.objectValue else { continue }
            let sid = snapObj["session_id"]?.stringValue ?? "?"
            let status = prettifiedAgentStatus(snapObj["status"]?.stringValue) ?? "unknown"
            let name = snapObj["session"]?.objectValue?["name"]?.stringValue
            var line = "- `\(sid)` — **\(status)**"
            if let name, !name.isEmpty {
                line += " (\(name))"
            }
            lines.append(line)
        }
        return [.text(lines.joined(separator: "\n"))]
    }

    static func formatAgentManage(args: [String: Value], value: Value) -> [MCP.Tool.Content] {
        guard let object = value.objectValue else {
            return formatGeneric(value: value)
        }
        let rawOp = args["op"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if rawOp == "extract_handoff" || rawOp == "handoff" {
            let outputPath = object["output_path"]?.stringValue
            let handoffXML = object["handoff_xml"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if outputPath == nil, let handoffXML, !handoffXML.isEmpty {
                return [.text(handoffXML)]
            }

            var handoffLines = ["**Agent manage · Extract Handoff**"]
            if let name = object["name"]?.stringValue, !name.isEmpty {
                handoffLines.append("- Name: `\(name)`")
            }
            if let sessionID = object["session_id"]?.stringValue, !sessionID.isEmpty {
                handoffLines.append("- Session: `\(sessionID)`")
            }
            if let source = object["source"]?.stringValue, !source.isEmpty {
                handoffLines.append("- Source: \(prettifiedAgentStatus(source) ?? source)")
            }
            if let status = object["file_contents_status"]?.stringValue, !status.isEmpty {
                handoffLines.append("- File contents: \(prettifiedAgentStatus(status) ?? status)")
            }
            if let outputPath, !outputPath.isEmpty {
                let bytes = object["bytes_written"]?.intValue ?? object["bytes"]?.intValue
                let suffix = bytes.map { " (\($0) bytes)" } ?? ""
                handoffLines.append("- Wrote: `\(outputPath)`\(suffix)")
            } else if let bytes = object["bytes"]?.intValue {
                handoffLines.append("- Bytes: \(bytes)")
            }
            if let handoffXML, !handoffXML.isEmpty {
                handoffLines.append("\n**Handoff XML**\n\n```xml\n\(handoffXML)\n```")
            }
            return [.text(handoffLines.joined(separator: "\n"))]
        }

        let op = prettifiedAgentControlOperation(args["op"]?.stringValue, fallback: "manage")
        var lines = ["**Agent manage · \(op)**"]

        if let name = object["name"]?.stringValue, !name.isEmpty {
            lines.append("- Name: `\(name)`")
        }
        if let sessionID = object["session_id"]?.stringValue, !sessionID.isEmpty {
            lines.append("- Session: `\(sessionID)`")
        }
        if let workflowName = object["workflow_name"]?.stringValue, !workflowName.isEmpty {
            lines.append("- Workflow: `\(workflowName)`")
        }
        if let agentObject = object["agent"]?.objectValue {
            let agentName = agentObject["name"]?.stringValue ?? agentObject["id"]?.stringValue
            if let agentName, !agentName.isEmpty {
                var agentLine = "- Agent: **\(agentName)**"
                if let model = agentObject["model"]?.stringValue, !model.isEmpty {
                    agentLine += " · `\(model)`"
                }
                lines.append(agentLine)
            }
        } else if let agent = object["agent"]?.stringValue, !agent.isEmpty {
            lines.append("- Agent: **\(agent)**")
        }
        let agentsArray = object["agents"]?.arrayValue
        let taskLabels = object["task_labels"]?.arrayValue
        if agentsArray != nil || (taskLabels?.isEmpty == false) {
            // Render resolved task labels if available, otherwise fall back to static list.
            // `task_labels` is the authoritative role-label surface; per-agent models below
            // are explicit compound `model_id` targets only.
            if let taskLabels, !taskLabels.isEmpty {
                lines.append("**Role labels** — authoritative `model_id` shortcuts:")
                for labelEntry in taskLabels {
                    guard let obj = labelEntry.objectValue,
                          let label = obj["label"]?.stringValue,
                          let name = obj["name"]?.stringValue else { continue }
                    lines.append("`\(label)` — \(name)")
                }
            } else if agentsArray != nil {
                lines.append("**Role labels** — pass as `model_id`:")
                lines.append("`explore` · `engineer` · `pair` · `design`")
            }
            lines.append("")
        }
        if let agents = agentsArray {
            for entry in agents {
                guard let agent = entry.objectValue else { continue }
                let name = agent["name"]?.stringValue ?? "Unknown"
                let available = agent["available"]?.boolValue == true

                lines.append("**\(name)**\(available ? "" : " *(unavailable)*")")
                let defaultModelID = agent["default_model_id"]?.stringValue
                guard let models = agent["models"]?.arrayValue, !models.isEmpty else { continue }

                // Group models by base ID (strip effort suffix) to collapse Codex families.
                // Per-agent model entries are explicit compound `model_id` targets only;
                // role routing is surfaced via top-level `task_labels` above.
                var families: [(base: String, name: String, efforts: [String])] = []
                var seen: Set<String> = []

                for model in models {
                    guard let m = model.objectValue else { continue }
                    let modelID = m["model_id"]?.stringValue ?? ""
                    let modelName = m["name"]?.stringValue ?? ""
                    let effort = m["reasoning_effort"]?.stringValue

                    // Extract base: everything after "agentRaw:" minus the effort suffix
                    let afterColon = modelID.contains(":") ? String(modelID[modelID.index(after: modelID.firstIndex(of: ":")!)...]) : modelID
                    let effortSuffixes = ["-low", "-medium", "-high", "-xhigh", "-none", "-minimal"]
                    var base = afterColon
                    for suffix in effortSuffixes where base.lowercased().hasSuffix(suffix) {
                        base = String(base.dropLast(suffix.count))
                        break
                    }
                    let agentPrefix = modelID.contains(":") ? String(modelID[...modelID.firstIndex(of: ":")!]) : ""
                    let familyKey = agentPrefix + base

                    if let effort, seen.contains(familyKey) {
                        // Add effort to existing family
                        if let idx = families.firstIndex(where: { familyKey == "\(agentPrefix)\($0.base)" }) {
                            families[idx].efforts.append(effort)
                        }
                    } else if effort != nil, !seen.contains(familyKey) {
                        // New family with efforts
                        seen.insert(familyKey)
                        let baseName = modelName
                            .replacingOccurrences(of: " Low", with: "")
                            .replacingOccurrences(of: " Medium", with: "")
                            .replacingOccurrences(of: " High", with: "")
                            .replacingOccurrences(of: " XHigh", with: "")
                            .trimmingCharacters(in: .whitespaces)
                        families.append((base: base, name: baseName, efforts: [effort!]))
                    } else {
                        // Simple model (no effort variants)
                        families.append((base: base, name: modelName, efforts: []))
                    }
                }

                let agentPrefix: String = {
                    guard let first = models.first?.objectValue?["model_id"]?.stringValue,
                          let colonIdx = first.firstIndex(of: ":") else { return "" }
                    return String(first[...colonIdx])
                }()

                for family in families {
                    if family.efforts.isEmpty {
                        if family.base == "default" { continue }
                        lines.append("  `\(agentPrefix)\(family.base)` — \(family.name)")
                    } else {
                        let effortList = family.efforts.joined(separator: "|")
                        lines.append("  `\(agentPrefix)\(family.base)-{\(effortList)}` — \(family.name)")
                    }
                }
            }
        }
        if let sessions = object["sessions"]?.arrayValue {
            lines.append("- Sessions: **\(sessions.count)**")
            for entry in sessions {
                guard let session = entry.objectValue else { continue }
                let name = session["name"]?.stringValue ?? "Unnamed"
                let state = session["state"]?.stringValue ?? ""
                let agentObject = session["agent"]?.objectValue
                let agent = agentObject?["name"]?.stringValue ?? agentObject?["id"]?.stringValue ?? session["agent"]?.stringValue ?? ""
                var parts: [String] = [name]
                if let sessionID = session["session_id"]?.stringValue, !sessionID.isEmpty {
                    parts.append("`\(sessionID)`")
                }
                if !state.isEmpty { parts.append(state) }
                if !agent.isEmpty { parts.append(agent) }
                lines.append("  - \(parts.joined(separator: " · "))")
            }
        }
        if let workflows = object["workflows"]?.arrayValue {
            lines.append("- Workflows: **\(workflows.count)**")
            for entry in workflows {
                guard let workflow = entry.objectValue else { continue }
                let name = workflow["name"]?.stringValue ?? workflow["id"]?.stringValue ?? "Unnamed"
                lines.append("  - \(name)")
            }
        }
        if let deletedCount = object["deleted_count"]?.intValue {
            let skippedCount = object["skipped_count"]?.intValue ?? 0
            lines.append("- Deleted: **\(deletedCount)** sessions")
            if skippedCount > 0 {
                lines.append("- Skipped: **\(skippedCount)** sessions")
            }
        }
        if let returned = object["returned_turn_count"]?.intValue,
           let total = object["total_turns"]?.intValue
        {
            lines.append("- Turns: **\(returned)/\(total)**")
            if let transcriptXML = object["transcript_xml"]?.stringValue,
               !transcriptXML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                lines.append("\n**Transcript**\n\n```xml\n\(transcriptXML)\n```")
            }
        }
        if lines.count == 1 {
            return formatGeneric(value: value)
        }
        return [.text(lines.joined(separator: "\n"))]
    }

    private static func humanizedAgentDelivery(_ raw: String?) -> String? {
        switch raw {
        case "started_run":
            "Started a new run."
        case "delivered_waiting_continuation":
            "Delivered immediately into the pending prompt."
        case "queued_follow_up":
            "Queued as the next turn once the active run reaches a safe handoff point."
        case "dispatched_codex_turn":
            "Delivered to the active Codex run."
        case "queued_claude_interrupt":
            "Queued for Claude and requested an interrupt at the next decision point."
        case "queued_acp_interrupt":
            "Queued for ACP and will cancel the active prompt before sending steering."
        case let raw? where !raw.isEmpty:
            prettifiedAgentStatus(raw)
        default:
            nil
        }
    }

    private static func prettifiedAgentStatus(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { word in
                guard let first = word.first else { return "" }
                return String(first).uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }

    private static func prettifiedAgentControlOperation(_ raw: String?, fallback: String) -> String {
        prettifiedAgentStatus(raw) ?? fallback.capitalized
    }

    /// Map file extension to code fence language tags.
    static func languageTag(forPath path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "m": return "objectivec"
        case "mm": return "objectivecpp"
        case "h", "hpp", "hh": return "cpp"
        case "c": return "c"
        case "cc", "cpp", "cxx": return "cpp"
        case "js", "mjs", "cjs": return "javascript"
        case "ts": return "typescript"
        case "tsx": return "tsx"
        case "jsx": return "jsx"
        case "py": return "python"
        case "rb": return "ruby"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "rs": return "rust"
        case "go": return "go"
        case "php": return "php"
        case "sh", "bash", "zsh": return "bash"
        case "yml", "yaml": return "yaml"
        case "json": return "json"
        case "toml": return "toml"
        case "md", "markdown": return "markdown"
        case "sql": return "sql"
        case "html", "htm": return "html"
        case "css": return "css"
        case "scss", "sass": return "scss"
        case "xml": return "xml"
        default: return ""
        }
    }

    /// Pretty-print Value as JSON for generic fallback display.
    static func prettyJSON(_ value: Value) -> String {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(value)
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            return "{}"
        }
    }

    private static func parseDiffArray(_ arr: [Value]) -> [(path: String, patch: String)] {
        var diffs: [(String, String)] = []
        for v in arr {
            if let obj = v.objectValue {
                let path = obj["path"]?.stringValue ?? obj["file"]?.stringValue ?? ""
                let patch = obj["patch"]?.stringValue
                    ?? obj["diff"]?.stringValue
                    ?? obj["diff_text"]?.stringValue
                    ?? ""
                if !path.isEmpty, !patch.isEmpty {
                    diffs.append((path, patch))
                }
            }
        }
        return diffs
    }

    // MARK: - Helpers (root grouping)

    private static func groupPathsByRoot(_ paths: [String]) -> [(root: String, paths: [String])] {
        var buckets: [String: [String]] = [:]
        for p in paths {
            let parts = p.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            let root = parts.first.map(String.init) ?? "(unknown)"
            let rest = parts.count > 1 ? String(parts[1]) : ""
            buckets[root, default: []].append(rest.isEmpty ? p : rest)
        }
        return buckets.keys.sorted().map { ($0, buckets[$0] ?? []) }
    }

    private static func rootName(for path: String) -> String {
        let parts = path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        return parts.first.map(String.init) ?? "(unknown)"
    }

    private static func groupFilesByRoot(_ entries: [(String, Int)]) -> [(root: String, items: [(String, Int)])] {
        var buckets: [String: [(String, Int)]] = [:]
        for (p, t) in entries {
            let root = rootName(for: p)
            buckets[root, default: []].append((p, t))
        }
        // Sort inner items by path
        for (k, v) in buckets {
            buckets[k] = v.sorted { $0.0 < $1.0 }
        }
        return buckets.keys.sorted().map { ($0, buckets[$0] ?? []) }
    }

    private static func groupInfosByRoot(_ infos: [ToolResultDTOs.SelectedFileInfo]) -> [(root: String, items: [ToolResultDTOs.SelectedFileInfo])] {
        var buckets: [String: [ToolResultDTOs.SelectedFileInfo]] = [:]
        for info in infos {
            let root = rootName(for: info.path)
            buckets[root, default: []].append(info)
        }
        for (key, values) in buckets {
            buckets[key] = values.sorted { lhs, rhs in
                lhs.path < rhs.path
            }
        }
        return buckets.keys.sorted().map { ($0, buckets[$0] ?? []) }
    }

    private static let selectionSectionOrder: [(key: String, title: String)] = [
        ("full", "Full Files"),
        ("slice", "Slice Files"),
        ("codemap", "Codemap Files"),
        ("other", "Other Files")
    ]

    private static func selectionRangeLookup(from slices: [ToolResultDTOs.FileSliceDTO]?) -> [String: [ToolResultDTOs.LineRangeDTO]] {
        guard let slices else { return [:] }
        var map: [String: [ToolResultDTOs.LineRangeDTO]] = [:]
        for slice in slices {
            map[slice.path] = slice.ranges
        }
        return map
    }

    private static func selectionCountBreakdownText(_ summary: ToolResultDTOs.SelectionSummary) -> String {
        var parts: [String] = []
        if summary.fullCount > 0 { parts.append("\(summary.fullCount) full") }
        if summary.sliceCount > 0 { parts.append("\(summary.sliceCount) slice") }
        if summary.codemapCount > 0 { parts.append("\(summary.codemapCount) codemap") }
        return parts.joined(separator: ", ")
    }

    private static func selectionTokenBreakdownText(_ summary: ToolResultDTOs.SelectionSummary) -> String {
        var parts: [String] = []
        if summary.fullTokens > 0 { parts.append("full \(summary.fullTokens)") }
        if summary.sliceTokens > 0 { parts.append("slice \(summary.sliceTokens)") }
        if summary.codemapTokens > 0 { parts.append("codemap \(summary.codemapTokens)") }
        return parts.joined(separator: ", ")
    }

    private static func sectionFilesByRenderMode(_ files: [ToolResultDTOs.SelectedFileInfo]) -> [String: [ToolResultDTOs.SelectedFileInfo]] {
        Dictionary(grouping: files) { info in
            switch info.renderMode {
            case "full": "full"
            case "slice": "slice"
            case "codemap": "codemap"
            default: "other"
            }
        }
    }

    private static func selectionTag(for info: ToolResultDTOs.SelectedFileInfo) -> String {
        switch info.renderMode {
        case "full":
            "[FULL]"
        case "slice":
            "[SLICE]"
        case "codemap":
            info.isAuto ? "[CODEMAP auto]" : "[CODEMAP]"
        default:
            "[\(info.renderMode.uppercased())]"
        }
    }

    /// Returns a concise origin suffix for codemap files, empty for non-codemaps
    private static func codemapOriginSuffix(for info: ToolResultDTOs.SelectedFileInfo) -> String {
        guard info.renderMode == "codemap" else { return "" }
        if let origin = info.codemapOrigin {
            switch origin {
            case "auto":
                return " (auto)"
            case "manual":
                return " (manual)"
            case "selected_mode":
                return " (selected)"
            default:
                return " (\(origin))"
            }
        }
        // Fallback to isAuto if codemapOrigin not set
        return info.isAuto ? " (auto)" : ""
    }

    private static func formatRanges(_ ranges: [ToolResultDTOs.LineRangeDTO]) -> String {
        ranges.map { range in
            let rangeStr = range.startLine == range.endLine ? "\(range.startLine)" : "\(range.startLine)-\(range.endLine)"
            if let desc = range.description, !desc.isEmpty {
                return "\(rangeStr) (\(desc))"
            }
            return rangeStr
        }
        .joined(separator: ", ")
    }

    /// Style for selection file listing output
    private enum SelectionListStyle {
        /// Path, line ranges, tokens, codemap origin (for power users / manage_selection)
        case detailed
        /// Path + line ranges only, minimal codemap labels (for workspace_context, embedded summaries)
        case compact
    }

    private static func selectionRangeSuffix(for info: ToolResultDTOs.SelectedFileInfo, rangeLookup: [String: [ToolResultDTOs.LineRangeDTO]]) -> String {
        let ranges = info.ranges ?? rangeLookup[info.path]
        guard let ranges, !ranges.isEmpty else { return "" }
        return " (ranges: \(formatRanges(ranges)))"
    }

    /// Formats a simple list of FileSliceDTO entries (for fallback scenarios when only slices exist)
    private static func selectionSlicesLines(slices: [ToolResultDTOs.FileSliceDTO]) -> [String] {
        var lines: [String] = []
        for slice in slices {
            let formatted = formatRanges(slice.ranges)
            lines.append("• `\(slice.path)` — lines \(formatted)")
        }
        return lines
    }

    private static func selectionSectionLines(
        files: [ToolResultDTOs.SelectedFileInfo],
        rangeLookup: [String: [ToolResultDTOs.LineRangeDTO]],
        showRootHeaders: Bool,
        style: SelectionListStyle = .detailed
    ) -> [String] {
        var lines: [String] = []
        let sectioned = sectionFilesByRenderMode(files)
        for (key, title) in selectionSectionOrder {
            guard let infos = sectioned[key], !infos.isEmpty else { continue }
            lines.append("")
            lines.append("#### \(title)")
            let groupedInfos = groupInfosByRoot(infos)
            for (root, entries) in groupedInfos {
                if showRootHeaders {
                    lines.append("##### Root: \(root)")
                }
                for info in entries {
                    let displayPath = showRootHeaders ? stripRootPrefix(info.path, root: root) : info.path
                    let ranges = info.ranges ?? rangeLookup[info.path]

                    switch style {
                    case .detailed:
                        // Emphasize ranges but keep tokens for manage_selection
                        var parts: [String] = []
                        if let ranges, !ranges.isEmpty {
                            let formatted = formatRanges(ranges)
                            parts.append("lines \(formatted)")
                        }
                        parts.append("\(info.tokens) tokens")
                        let originSuffix = codemapOriginSuffix(for: info)
                        if !originSuffix.isEmpty {
                            parts.append(originSuffix.trimmingCharacters(in: .whitespaces))
                        }
                        let details = parts.joined(separator: " — ")
                        lines.append("• `\(displayPath)` — \(details)")

                    case .compact:
                        if let ranges, !ranges.isEmpty {
                            let formatted = formatRanges(ranges)
                            lines.append("• `\(displayPath)` — lines \(formatted)")
                        } else if info.renderMode == "codemap" {
                            let originSuffix = codemapOriginSuffix(for: info)
                            let codemapLabel = originSuffix.isEmpty ? "codemap" : "codemap\(originSuffix)"
                            lines.append("• `\(displayPath)` — \(codemapLabel)")
                        } else {
                            // Full file, no slice info; keep it very short
                            lines.append("• `\(displayPath)`")
                        }
                    }
                }
            }
        }
        return lines
    }

    private static func stripRootPrefix(_ full: String, root: String) -> String {
        if full.hasPrefix(root + "/") {
            return String(full.dropFirst(root.count + 1))
        }
        return full
    }
}
