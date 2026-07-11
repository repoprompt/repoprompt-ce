import Foundation
import SwiftUI

struct ApplyEditsResultCard: View {
    let item: AgentChatItem
    let isMostRecentEdit: Bool
    @State private var isExpanded: Bool
    @State private var cachedPresentation: Presentation?
    private static let legacySummaryDiffScanByteThreshold = 24000

    init(item: AgentChatItem, isMostRecentEdit: Bool = true) {
        self.item = item
        self.isMostRecentEdit = isMostRecentEdit
        _isExpanded = State(initialValue: Self.shouldAutoExpandInitially(item: item, isMostRecentEdit: isMostRecentEdit))
        _cachedPresentation = State(initialValue: nil)
    }

    private static func shouldAutoExpandInitially(item: AgentChatItem, isMostRecentEdit: Bool) -> Bool {
        guard isMostRecentEdit else { return false }
        let dto = ToolJSON.decode(ToolResultDTOs.EditSummary.self, from: item.toolResultJSON)
        // Keep the most recent live apply_edits card openable when it carries an in-memory
        // compact preview diff, even if the payload is otherwise summary-oriented.
        if hasCompactDisplayDiff(dto) {
            return true
        }
        guard toolResultHasPayload(item), !toolResultIsSummaryOnly(item) else { return false }
        if let dto {
            if dto.requiresUserApproval == true {
                return true
            }
        }
        let status = ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral)
        return status != .failure
    }

    private struct Presentation {
        let dto: ToolResultDTOs.EditSummary?
        let displayDiff: String?
        let summary: String
        let status: ToolCardStatus
        let isExpandable: Bool
        let renderMode: AgentToolCardRenderMode
    }

    private struct PresentationCacheKey: Equatable {
        let toolResultJSON: String?
        let toolArgsJSON: String?
    }

    private var presentationCacheKey: PresentationCacheKey {
        PresentationCacheKey(toolResultJSON: item.toolResultJSON, toolArgsJSON: item.toolArgsJSON)
    }

    private func buildPresentation() -> Presentation {
        let dto = ToolJSON.decode(ToolResultDTOs.EditSummary.self, from: item.toolResultJSON)
        let args = ToolJSON.decodeArgs(ToolArgsDTOs.ApplyEditsArgs.self, from: item.toolArgsJSON)
        let displayDiff = Self.resolvedDisplayDiff(from: dto)
        let status = resolvedStatus(from: dto)
        return Presentation(
            dto: dto,
            displayDiff: displayDiff,
            summary: buildSummary(dto: dto, diff: displayDiff, path: args?.path),
            status: status,
            isExpandable: (displayDiff?.isEmpty == false) || (toolResultHasPayload(item) && !toolResultIsSummaryOnly(item)),
            renderMode: resolvedApplyEditsRenderMode(dto: dto, displayDiff: displayDiff)
        )
    }

    private static func resolvedDisplayDiff(from dto: ToolResultDTOs.EditSummary?) -> String? {
        guard let dto else { return nil }
        if let diff = dto.cardUnifiedDiff, !diff.isEmpty {
            return diff
        }
        if let diff = dto.unifiedDiff, !diff.isEmpty {
            return diff
        }
        return nil
    }

    private static func hasCompactDisplayDiff(_ dto: ToolResultDTOs.EditSummary?) -> Bool {
        resolvedDisplayDiff(from: dto)?.isEmpty == false
    }

    private func buildSummary(dto: ToolResultDTOs.EditSummary?, diff: String?, path: String?) -> String {
        var parts: [String] = []
        if let path {
            parts.append(fileName(from: path))
        }
        if let dto {
            parts.append("\(dto.editsApplied)/\(dto.editsRequested) edits")
            if let lineChange = lineChangeFragment(dto: dto, diff: diff) {
                parts.append(lineChange)
            }
        }
        return parts.joined(separator: " • ")
    }

    private func lineChangeFragment(dto: ToolResultDTOs.EditSummary, diff: String?) -> String? {
        if dto.addedLines != nil || dto.deletedLines != nil {
            let addedLines = dto.addedLines ?? 0
            let deletedLines = dto.deletedLines ?? 0
            if addedLines > 0 || deletedLines > 0 {
                return "+\(addedLines) -\(deletedLines) lines"
            }
        }
        if let diff, let counts = countDiffLinesIfCheap(diff), counts.adds > 0 || counts.dels > 0 {
            return "+\(counts.adds) -\(counts.dels) lines"
        }
        if let changed = dto.totalLinesChanged {
            return "\(changed) lines"
        }
        return nil
    }

    private func resolvedApplyEditsRenderMode(dto: ToolResultDTOs.EditSummary?, displayDiff: String?) -> AgentToolCardRenderMode {
        if displayDiff?.isEmpty == false {
            return .diffPreview
        }
        if dto != nil {
            return .markdownFallback
        }
        return .markdownFallback
    }

    private func resolvedStatus(from dto: ToolResultDTOs.EditSummary?) -> ToolCardStatus {
        if item.toolIsError == true {
            return .failure
        }
        if let dto {
            switch dto.status.lowercased() {
            case "success": return .success
            case "partial", "warning": return .warning
            case "failed", "error": return .failure
            default: break
            }
        }
        return ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral)
    }

    private func countDiffLinesIfCheap(_ diff: String) -> (adds: Int, dels: Int)? {
        guard diff.utf8.count <= Self.legacySummaryDiffScanByteThreshold else { return nil }
        var adds = 0
        var dels = 0
        for line in diff.components(separatedBy: "\n") {
            if line.hasPrefix("+"), !line.hasPrefix("+++") {
                adds += 1
            } else if line.hasPrefix("-"), !line.hasPrefix("---") {
                dels += 1
            }
        }
        return (adds, dels)
    }

    var body: some View {
        let presentation = cachedPresentation ?? buildPresentation()
        ToolCardContainer(
            iconName: toolIcon(for: item.toolName),
            iconColor: ToolCardAccentResolver.color(for: item.toolName),
            title: "Edit",
            subtitle: nonEmptyToolCardSummary(presentation.summary, fallbackStatusFor: item),
            status: presentation.status,
            timestamp: item.timestamp,
            isExpandable: presentation.isExpandable,
            managesOwnExpansion: true,
            debugItemID: item.id,
            debugToolName: "apply_edits",
            debugRenderMode: presentation.renderMode,
            isExpanded: $isExpanded
        ) {
            if let dto = presentation.dto {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if dto.fileCreated == true {
                            StatusBadge(text: "created", status: .success)
                        }
                        if dto.fileOverwritten == true {
                            StatusBadge(text: "overwritten", status: .warning)
                        }
                    }
                    if let note = dto.note, !note.isEmpty {
                        Text(note)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    if let diff = presentation.displayDiff {
                        UnifiedDiffView(diff: diff, largeBodyMaxHeight: 560)
                    } else {
                        ToolMarkdownExpandedContent(item: item)
                    }
                }
            } else {
                ToolMarkdownExpandedContent(item: item)
            }
        }
        .onAppear {
            cachedPresentation = buildPresentation()
        }
        .onChange(of: presentationCacheKey) { _, _ in
            cachedPresentation = buildPresentation()
        }
        .onChange(of: isMostRecentEdit) { _, isMostRecent in
            if !isMostRecent, isExpanded {
                performAgentToolCardExpansionStateUpdateWithoutAnimation {
                    isExpanded = false
                }
            }
        }
    }
}

struct CursorNativeEditResultPresentation: Equatable {
    struct DisplayDiff: Equatable {
        let path: String
        let diff: String
        let isTruncated: Bool
    }

    let dto: ToolResultDTOs.CursorNativeEditSummary?
    let title: String
    let summary: String
    let diffs: [DisplayDiff]
    let status: ToolCardStatus
    let isExpandable: Bool
    let renderMode: AgentToolCardRenderMode

    static func build(for item: AgentChatItem) -> CursorNativeEditResultPresentation {
        let dto = ToolJSON.decode(ToolResultDTOs.CursorNativeEditSummary.self, from: item.toolResultJSON)
        let diffs = displayDiffs(from: dto)
        let title = displayTitle(from: dto)
        let status = resolvedStatus(item: item, dto: dto, diffs: diffs)
        return CursorNativeEditResultPresentation(
            dto: dto,
            title: title,
            summary: buildSummary(dto: dto, diffs: diffs),
            diffs: diffs,
            status: status,
            isExpandable: !diffs.isEmpty || (toolResultHasPayload(item) && !toolResultIsSummaryOnly(item)),
            renderMode: diffs.isEmpty ? .markdownFallback : .diffPreview
        )
    }

    static func shouldAutoExpandInitially(item: AgentChatItem, isMostRecentEdit: Bool) -> Bool {
        guard isMostRecentEdit else { return false }
        return !displayDiffs(from: ToolJSON.decode(ToolResultDTOs.CursorNativeEditSummary.self, from: item.toolResultJSON)).isEmpty
    }

    private static func displayTitle(from dto: ToolResultDTOs.CursorNativeEditSummary?) -> String {
        let rawTitle = dto?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawTitle, !rawTitle.isEmpty else { return "Edit File" }
        if rawTitle.lowercased() == "edit file" {
            return "Edit File"
        }
        return rawTitle
    }

    private static func buildSummary(
        dto: ToolResultDTOs.CursorNativeEditSummary?,
        diffs: [DisplayDiff]
    ) -> String {
        let truncationSuffix = diffs.contains { $0.isTruncated } ? " • diff truncated" : ""
        if let first = diffs.first {
            if diffs.count == 1 {
                return "\(fileName(from: first.path)) • edit\(truncationSuffix)"
            }
            return "\(diffs.count) files • edit\(truncationSuffix)"
        }
        if let changeCount = dto?.changeCount, changeCount > 0 {
            return "\(changeCount) file\(changeCount == 1 ? "" : "s") • edit"
        }
        return "Edit"
    }

    private static func displayDiffs(from dto: ToolResultDTOs.CursorNativeEditSummary?) -> [DisplayDiff] {
        guard let content = dto?.content else { return [] }
        return content.compactMap { block in
            let blockType = block.type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard blockType == nil || blockType == "diff",
                  let rawPath = block.path?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawPath.isEmpty
            else {
                return nil
            }
            let isTruncated = block.diffTruncated == true
                || block.oldTextTruncated == true
                || block.newTextTruncated == true
            if let persistedDiff = block.unifiedDiff?.trimmingCharacters(in: .whitespacesAndNewlines),
               !persistedDiff.isEmpty
            {
                return DisplayDiff(path: rawPath, diff: persistedDiff, isTruncated: isTruncated)
            }
            guard let oldText = block.oldText,
                  let newText = block.newText else { return nil }
            let diff = unifiedDiff(path: rawPath, oldText: oldText, newText: newText)
            guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return DisplayDiff(path: rawPath, diff: diff, isTruncated: isTruncated)
        }
    }

    private static func unifiedDiff(path: String, oldText: String, newText: String) -> String {
        let oldLines = String.splitContentPreservingLineEndings(oldText).0
        let newLines = String.splitContentPreservingLineEndings(newText).0
        let chunks = UnifiedDiffGenerator.diffChunks(
            oldLines: oldLines,
            newLines: newLines,
            context: 2
        )
        return UnifiedDiffGenerator.build(filePath: path, chunks: chunks, context: 2)
    }

    private static func resolvedStatus(
        item: AgentChatItem,
        dto: ToolResultDTOs.CursorNativeEditSummary?,
        diffs: [DisplayDiff]
    ) -> ToolCardStatus {
        let primary = ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral)
        if primary == .failure || primary == .warning {
            return primary
        }
        if diffs.contains(where: \.isTruncated) {
            return .warning
        }
        if let acpStatus = cursorStatusWord(dto?.acpStatus) {
            return acpStatus
        }
        if primary != .neutral {
            return primary
        }
        return cursorStatusWord(dto?.status) ?? primary
    }

    private static func cursorStatusWord(_ value: String?) -> ToolCardStatus? {
        guard let normalized = AgentTranscriptToolStatusSemantics.normalizedStatusWord(value) else { return nil }
        switch normalized {
        case "success": return .success
        case "warning": return .warning
        case "failed", "cancelled": return .failure
        case "running", "pending": return .running
        default: return nil
        }
    }
}

struct CursorNativeEditResultCard: View {
    let item: AgentChatItem
    let isMostRecentEdit: Bool
    @State private var isExpanded: Bool
    @State private var cachedPresentation: CursorNativeEditResultPresentation?

    init(item: AgentChatItem, isMostRecentEdit: Bool = true) {
        self.item = item
        self.isMostRecentEdit = isMostRecentEdit
        _isExpanded = State(initialValue: CursorNativeEditResultPresentation.shouldAutoExpandInitially(
            item: item,
            isMostRecentEdit: isMostRecentEdit
        ))
        _cachedPresentation = State(initialValue: nil)
    }

    private struct PresentationCacheKey: Equatable {
        let toolName: String?
        let toolResultJSON: String?
        let toolArgsJSON: String?
        let toolIsError: Bool?
    }

    private var presentationCacheKey: PresentationCacheKey {
        PresentationCacheKey(
            toolName: item.toolName,
            toolResultJSON: item.toolResultJSON,
            toolArgsJSON: item.toolArgsJSON,
            toolIsError: item.toolIsError
        )
    }

    var body: some View {
        let presentation = cachedPresentation ?? CursorNativeEditResultPresentation.build(for: item)
        ToolCardContainer(
            iconName: toolIcon(for: item.toolName),
            iconColor: ToolCardAccentResolver.color(for: item.toolName),
            title: presentation.title,
            subtitle: nonEmptyToolCardSummary(presentation.summary, fallbackStatusFor: item),
            status: presentation.status,
            timestamp: item.timestamp,
            isExpandable: presentation.isExpandable,
            managesOwnExpansion: true,
            debugItemID: item.id,
            debugToolName: "edit",
            debugRenderMode: presentation.renderMode,
            isExpanded: $isExpanded
        ) {
            if presentation.diffs.isEmpty {
                ToolMarkdownExpandedContent(item: item)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(presentation.diffs.enumerated()), id: \.offset) { _, diff in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(shortenPath(diff.path))
                                .font(.system(size: 11, weight: .semibold))
                                .textSelection(.enabled)
                            if diff.isTruncated {
                                Text("Diff truncated")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            UnifiedDiffView(diff: diff.diff, largeBodyMaxHeight: 440)
                        }
                    }
                }
            }
        }
        .onAppear {
            cachedPresentation = CursorNativeEditResultPresentation.build(for: item)
        }
        .onChange(of: presentationCacheKey) { _, _ in
            cachedPresentation = CursorNativeEditResultPresentation.build(for: item)
        }
        .onChange(of: isMostRecentEdit) { _, isMostRecent in
            if !isMostRecent, isExpanded {
                performAgentToolCardExpansionStateUpdateWithoutAnimation {
                    isExpanded = false
                }
            }
        }
    }
}

struct ApplyPatchResultCard: View {
    let item: AgentChatItem
    let isMostRecentEdit: Bool
    @State private var isExpanded: Bool
    @State private var cachedPresentation: Presentation?

    init(item: AgentChatItem, isMostRecentEdit: Bool = true) {
        self.item = item
        self.isMostRecentEdit = isMostRecentEdit
        _isExpanded = State(initialValue: Self.shouldAutoExpandInitially(item: item, isMostRecentEdit: isMostRecentEdit))
        _cachedPresentation = State(initialValue: nil)
    }

    private static func shouldAutoExpandInitially(item: AgentChatItem, isMostRecentEdit: Bool) -> Bool {
        guard isMostRecentEdit, toolResultHasPayload(item), !toolResultIsSummaryOnly(item) else { return false }
        guard let dto = ToolJSON.decode(ToolResultDTOs.ApplyPatchSummary.self, from: item.toolResultJSON) else {
            return false
        }
        return !dto.changes.isEmpty
    }

    private struct Presentation {
        let dto: ToolResultDTOs.ApplyPatchSummary?
        let summary: String
        let status: ToolCardStatus
        let isExpandable: Bool
        let renderMode: AgentToolCardRenderMode
    }

    private struct PresentationCacheKey: Equatable {
        let toolResultJSON: String?
        let toolArgsJSON: String?
    }

    private var presentationCacheKey: PresentationCacheKey {
        PresentationCacheKey(toolResultJSON: item.toolResultJSON, toolArgsJSON: item.toolArgsJSON)
    }

    private func buildPresentation() -> Presentation {
        let dto = ToolJSON.decode(ToolResultDTOs.ApplyPatchSummary.self, from: item.toolResultJSON)
        let args = ToolJSON.decodeArgs(ToolArgsDTOs.ApplyPatchArgs.self, from: item.toolArgsJSON)
        let changeCount = resolvedChangeCount(dto: dto, args: args)
        return Presentation(
            dto: dto,
            summary: buildSummary(dto: dto, args: args, changeCount: changeCount),
            status: resolvedStatus(from: dto),
            isExpandable: toolResultHasPayload(item) && !toolResultIsSummaryOnly(item),
            renderMode: resolvedApplyPatchRenderMode(dto: dto)
        )
    }

    private func resolvedApplyPatchRenderMode(dto: ToolResultDTOs.ApplyPatchSummary?) -> AgentToolCardRenderMode {
        guard let dto else { return .markdownFallback }
        if dto.changes.contains(where: { isUnifiedDiff($0.diff, kind: $0.kind) }) {
            return .diffPreview
        }
        if dto.changes.isEmpty {
            if let output = dto.output, !output.isEmpty {
                return .toolSpecificNoDiff
            }
            return .markdownFallback
        }
        return .toolSpecificNoDiff
    }

    private func resolvedChangeCount(dto: ToolResultDTOs.ApplyPatchSummary?, args: ToolArgsDTOs.ApplyPatchArgs?) -> Int {
        if let dto {
            return max(dto.changeCount, dto.changes.count)
        }
        if let count = args?.changeCount {
            return count
        }
        return 0
    }

    private func buildSummary(dto: ToolResultDTOs.ApplyPatchSummary?, args: ToolArgsDTOs.ApplyPatchArgs?, changeCount: Int) -> String {
        if let dto, let firstChange = dto.changes.first {
            let totalChanges = max(dto.changeCount, dto.changes.count)
            if totalChanges == 1 {
                return "\(fileName(from: firstChange.path)) • patch"
            }
            return "\(totalChanges) files • patch"
        }
        if let args {
            if let path = args.path, !path.isEmpty {
                return "\(fileName(from: path)) • patch"
            }
            if let paths = args.paths, !paths.isEmpty {
                if paths.count == 1 {
                    return "\(fileName(from: paths[0])) • patch"
                }
                return "\(paths.count) files • patch"
            }
            if let changeCount = args.changeCount, changeCount > 0 {
                return "\(changeCount) file\(changeCount == 1 ? "" : "s") • patch"
            }
        }
        if changeCount > 0 {
            return "\(changeCount) file\(changeCount == 1 ? "" : "s") • patch"
        }
        return "Patch"
    }

    private func resolvedStatus(from dto: ToolResultDTOs.ApplyPatchSummary?) -> ToolCardStatus {
        guard let dto else {
            return ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral)
        }
        switch dto.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "running", "in_progress", "inprogress", "pending":
            return .neutral
        case "completed", "success", "succeeded", "ok":
            return .success
        case "declined", "rejected":
            return .warning
        case "failed", "failure", "error":
            return .failure
        default:
            return ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral)
        }
    }

    var body: some View {
        let presentation = cachedPresentation ?? buildPresentation()
        ToolCardContainer(
            iconName: toolIcon(for: item.toolName),
            iconColor: ToolCardAccentResolver.color(for: item.toolName),
            title: "Patch",
            subtitle: nonEmptyToolCardSummary(presentation.summary, fallbackStatusFor: item),
            status: presentation.status,
            timestamp: item.timestamp,
            isExpandable: presentation.isExpandable,
            managesOwnExpansion: true,
            debugItemID: item.id,
            debugToolName: "apply_patch",
            debugRenderMode: presentation.renderMode,
            isExpanded: $isExpanded
        ) {
            if let dto = presentation.dto {
                VStack(alignment: .leading, spacing: 10) {
                    if dto.changes.isEmpty {
                        if let output = dto.output, !output.isEmpty {
                            ToolScrollableMarkdownTextView(text: output, maxHeight: 180)
                        } else {
                            ToolMarkdownExpandedContent(item: item)
                        }
                    } else {
                        ForEach(Array(dto.changes.enumerated()), id: \.offset) { _, change in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(shortenPath(change.path))
                                        .font(.system(size: 11, weight: .semibold))
                                        .textSelection(.enabled)
                                    if let movePath = change.movePath, !movePath.isEmpty {
                                        Text("→ \(shortenPath(movePath))")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }
                                }
                                if isUnifiedDiff(change.diff, kind: change.kind) {
                                    UnifiedDiffView(diff: change.diff, largeBodyMaxHeight: 440)
                                } else {
                                    ToolScrollableMarkdownTextView(text: change.diff, maxHeight: 180)
                                }
                            }
                        }
                    }
                }
            } else {
                ToolMarkdownExpandedContent(item: item)
            }
        }
        .onAppear {
            cachedPresentation = buildPresentation()
        }
        .onChange(of: presentationCacheKey) { _, _ in
            cachedPresentation = buildPresentation()
        }
        .onChange(of: isMostRecentEdit) { _, isMostRecent in
            if !isMostRecent, isExpanded {
                performAgentToolCardExpansionStateUpdateWithoutAnimation {
                    isExpanded = false
                }
            }
        }
    }

    private func isUnifiedDiff(_ diff: String, kind: String) -> Bool {
        let normalizedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedKind != "update" {
            return false
        }
        let trimmed = diff.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@@") || trimmed.contains("--- ") || trimmed.contains("+++ ")
    }
}
