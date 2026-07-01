import Foundation
import SwiftUI

struct FileTreeCardPresentation: Equatable {
    let subtitle: String
    let detailText: String?
    let status: ToolCardStatus
}

enum FileTreeCardPresentationBuilder {
    static func build(dto: ToolResultDTOs.FileTreeDTO?, args: ToolArgsDTOs.FileTreeArgs?, toolIsError: Bool?, raw: String?) -> FileTreeCardPresentation {
        if let stored = StoredToolCardPresentation.fromSummaryOnly(raw: raw) {
            return FileTreeCardPresentation(
                subtitle: stored.subtitle ?? stored.inlineSubtitle ?? "File tree",
                detailText: stored.detailText,
                status: toolIsError == true ? .failure : (stored.status ?? ToolResultStatusResolver.resolve(toolIsError: toolIsError, raw: raw, fallback: .neutral))
            )
        }
        if toolIsError == true {
            return FileTreeCardPresentation(
                subtitle: fallbackSubtitle(dto: dto, args: args),
                detailText: dto?.note,
                status: .failure
            )
        }
        guard let dto else {
            return FileTreeCardPresentation(
                subtitle: fallbackSubtitle(dto: nil, args: args),
                detailText: nil,
                status: ToolResultStatusResolver.resolve(toolIsError: toolIsError, raw: raw, fallback: .neutral)
            )
        }

        let treeType = normalizedTreeType(dto: dto, args: args)
        let mode = normalizedMode(args?.mode)
        let startPath = normalizedStartPath(args?.path)
        let isFallbackMessage = dto.note != nil
        let wasTruncated = dto.wasTruncated == true
        let status: ToolCardStatus = {
            if isFallbackMessage || wasTruncated { return .warning }
            if !dto.tree.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .success }
            return .neutral
        }()

        if isFallbackMessage {
            let subtitle = treeType == "roots"
                ? "File tree unavailable"
                : (fileTreeFilesSubtitle(mode: mode, startPath: startPath) ?? "File tree unavailable")
            return FileTreeCardPresentation(
                subtitle: subtitle,
                detailText: dto.note ?? fallbackDetailText(startPath: startPath),
                status: status
            )
        }

        if treeType == "roots" {
            return FileTreeCardPresentation(
                subtitle: rootCountText(dto.rootsCount),
                detailText: nil,
                status: status
            )
        }

        return FileTreeCardPresentation(
            subtitle: fileTreeFilesSubtitle(mode: mode, startPath: startPath, rootsCount: startPath == nil ? dto.rootsCount : nil) ?? "File tree",
            detailText: nil,
            status: status
        )
    }

    private static func normalizedTreeType(dto: ToolResultDTOs.FileTreeDTO, args: ToolArgsDTOs.FileTreeArgs?) -> String {
        if let raw = args?.type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty {
            return raw
        }
        if args?.mode != nil || args?.path != nil || args?.maxDepth != nil || dto.usesLegend {
            return "files"
        }
        if dto.tree.contains("├──") || dto.tree.contains("└──") {
            return "files"
        }
        return "roots"
    }

    private static func normalizedMode(_ raw: String?) -> String {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "full":
            "full"
        case "folders":
            "folders"
        case "selected":
            "selected"
        default:
            "auto"
        }
    }

    private static func fileTreeModeTitle(_ mode: String) -> String {
        switch mode {
        case "full":
            "Full"
        case "folders":
            "Folders"
        case "selected":
            "Selected"
        default:
            "Auto"
        }
    }

    private static func fileTreeFilesSubtitle(mode: String, startPath: String?, rootsCount: Int? = nil) -> String? {
        var parts = [fileTreeModeTitle(mode)]
        if let startPath = normalizedStartPath(startPath) {
            parts.append(shortenPath(startPath))
        } else if let rootsCount {
            parts.append(rootCountText(rootsCount))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private static func fallbackSubtitle(dto: ToolResultDTOs.FileTreeDTO?, args: ToolArgsDTOs.FileTreeArgs?) -> String {
        let treeType = dto.flatMap { normalizedTreeType(dto: $0, args: args) } ?? (args?.type?.lowercased() == "roots" ? "roots" : "files")
        if treeType == "roots" {
            return dto.map { rootCountText($0.rootsCount) } ?? "roots"
        }
        return fileTreeFilesSubtitle(
            mode: normalizedMode(args?.mode),
            startPath: args?.path,
            rootsCount: args?.path == nil ? dto?.rootsCount : nil
        ) ?? "File tree"
    }

    private static func fallbackDetailText(startPath: String?) -> String {
        if let startPath = normalizedStartPath(startPath) {
            return "Unable to show a tree for \(shortenPath(startPath))."
        }
        return "File tree unavailable for the current workspace."
    }

    private static func normalizedStartPath(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        if trimmed == "." || trimmed == "./" {
            return nil
        }
        return trimmed
    }

    private static func rootCountText(_ count: Int) -> String {
        "\(count) root\(count == 1 ? "" : "s")"
    }
}

struct FileTreeResultCard: View {
    let item: AgentChatItem
    @State private var isExpanded = false

    private var dto: ToolResultDTOs.FileTreeDTO? {
        ToolJSON.decode(ToolResultDTOs.FileTreeDTO.self, from: item.toolResultJSON)
    }

    private var args: ToolArgsDTOs.FileTreeArgs? {
        ToolJSON.decodeArgs(ToolArgsDTOs.FileTreeArgs.self, from: item.toolArgsJSON)
    }

    private var presentation: FileTreeCardPresentation {
        FileTreeCardPresentationBuilder.build(dto: dto, args: args, toolIsError: item.toolIsError, raw: item.toolResultJSON)
    }

    var body: some View {
        ToolCardContainer(
            iconName: toolIcon(for: item.toolName),
            iconColor: ToolCardAccentResolver.color(for: item.toolName),
            title: "File Tree",
            detailText: nil,
            subtitle: inlineToolCardSummary(presentation.subtitle, presentation.detailText),
            status: presentation.status,
            timestamp: item.timestamp,
            isExpandable: toolResultHasPayload(item),
            isExpanded: $isExpanded
        ) {
            ToolMarkdownExpandedContent(item: item)
        }
    }
}

struct CodeStructureResultCard: View {
    let item: AgentChatItem
    @State private var isExpanded = false

    private var dto: ToolResultDTOs.CodeStructureReplyDTO? {
        ToolJSON.decode(ToolResultDTOs.CodeStructureReplyDTO.self, from: item.toolResultJSON)
    }

    private var headerStatusText: String? {
        nil
    }

    private var detailText: String? {
        if let stored = StoredToolCardPresentation.fromSummaryOnly(raw: item.toolResultJSON) {
            return stored.detailText
        }
        guard let paths = dto?.issues.compactMap(\.path), !paths.isEmpty else { return nil }
        let visible = paths.prefix(2).map { shortenPath($0) }
        var parts = visible
        if paths.count > visible.count {
            parts.append("(+\(paths.count - visible.count) more)")
        }
        return parts.joined(separator: " • ")
    }

    private var summary: String {
        if let stored = StoredToolCardPresentation.fromSummaryOnly(raw: item.toolResultJSON) {
            return stored.subtitle ?? ""
        }
        if let dto {
            return "\(dto.summary.returnedFiles) files • \(dto.status)"
        }
        if let args = ToolJSON.decodeArgs(ToolArgsDTOs.CodeStructureArgs.self, from: item.toolArgsJSON) {
            if args.scope == "selected" { return "selected" }
            if let count = args.paths?.count, count > 0 {
                return "\(count) path\(count == 1 ? "" : "s")"
            }
        }
        return ""
    }

    private var status: ToolCardStatus {
        if item.toolIsError == true { return .failure }
        if let storedStatus = StoredToolCardPresentation.fromSummaryOnly(raw: item.toolResultJSON)?.status {
            return storedStatus
        }
        if let dto {
            return switch dto.status {
            case "ready": .success
            case "partial", "pending", "budget": .warning
            case "unavailable", "stale": .failure
            default: .neutral
            }
        }
        return ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral)
    }

    var body: some View {
        ToolCardContainer(
            iconName: toolIcon(for: item.toolName),
            iconColor: ToolCardAccentResolver.color(for: item.toolName),
            title: "Code Structure",
            detailText: nil,
            subtitle: inlineToolCardSummary(summary, detailText),
            status: status,
            timestamp: item.timestamp,
            isExpandable: toolResultHasPayload(item),
            isExpanded: $isExpanded
        ) {
            ToolMarkdownExpandedContent(item: item)
        }
    }
}

struct ManageSelectionResultCard: View {
    let item: AgentChatItem
    @State private var isExpanded = false

    private var dto: ToolResultDTOs.SelectionReply? {
        ToolJSON.decode(ToolResultDTOs.SelectionReply.self, from: item.toolResultJSON)
    }

    private var detailText: String? {
        if let stored = StoredToolCardPresentation.fromSummaryOnly(raw: item.toolResultJSON) {
            return stored.detailText
        }
        guard let summary = dto?.summary else { return nil }
        let parts = [
            "\(summary.fullCount) full",
            "\(summary.sliceCount) sliced",
            "\(summary.codemapCount) codemap"
        ]
        return parts.joined(separator: " • ")
    }

    private var summary: String {
        if let summary = StoredToolCardPresentation.fromSummaryOnly(raw: item.toolResultJSON)?.subtitle {
            return summary
        }
        let op = ToolJSON.decodeArgs(ToolArgsDTOs.ManageSelectionArgs.self, from: item.toolArgsJSON)?.op ?? "get"
        var parts: [String] = [op]
        if let dto {
            if let files = dto.files?.count {
                parts.append("\(files) files")
            }
            if let totalTokens = dto.totalTokens {
                parts.append("\(totalTokens) tokens")
            }
            if parts.count == 1, let invalid = dto.invalidPaths?.count, invalid > 0 {
                parts.append("\(invalid) invalid")
            }
        }
        return parts.joined(separator: " • ")
    }

    private var status: ToolCardStatus {
        if item.toolIsError == true { return .failure }
        if let status = StoredToolCardPresentation.fromSummaryOnly(raw: item.toolResultJSON)?.status {
            return status
        }
        let resolved = dto.flatMap { ToolResultStatusResolver.mapStatusWord($0.status) }
            ?? ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral)
        if let invalidCount = dto?.invalidPaths?.count, invalidCount > 0, resolved == .success || resolved == .neutral {
            return .warning
        }
        return resolved
    }

    var body: some View {
        ToolCardContainer(
            iconName: toolIcon(for: item.toolName),
            iconColor: ToolCardAccentResolver.color(for: item.toolName),
            title: "Selection",
            detailText: nil,
            subtitle: inlineToolCardSummary(summary, detailText),
            status: status,
            timestamp: item.timestamp,
            isExpandable: toolResultHasPayload(item),
            isExpanded: $isExpanded
        ) {
            ToolMarkdownExpandedContent(item: item)
        }
    }
}

struct WorkspaceContextResultCard: View {
    let item: AgentChatItem
    @State private var isExpanded = false

    private var dto: ToolResultDTOs.PromptContextDTO? {
        ToolJSON.decode(ToolResultDTOs.PromptContextDTO.self, from: item.toolResultJSON)
    }

    private var detailText: String? {
        if let stored = StoredToolCardPresentation.fromSummaryOnly(raw: item.toolResultJSON) {
            return stored.detailText
        }
        guard let dto else { return nil }
        var sections: [String] = []
        if !dto.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sections.append("prompt") }
        if dto.selection != nil { sections.append("selection") }
        if dto.fileTree != nil { sections.append("file tree") }
        if dto.codeStructure != nil { sections.append("code structure") }
        if dto.fileBlocks?.isEmpty == false { sections.append("file blocks") }
        if dto.copyPreset != nil { sections.append("copy preset") }
        if dto.copyPresets?.isEmpty == false { sections.append("presets") }
        guard !sections.isEmpty else { return nil }
        let visible = Array(sections.prefix(3))
        if sections.count > visible.count {
            return visible.joined(separator: " • ") + " • +\(sections.count - visible.count) more"
        }
        return visible.joined(separator: " • ")
    }

    private var summary: String {
        if let summary = StoredToolCardPresentation.fromSummaryOnly(raw: item.toolResultJSON)?.subtitle {
            return summary
        }
        guard let dto else { return "snapshot" }
        var parts: [String] = []
        if let selection = dto.selection {
            parts.append("\(selection.files.count) files")
            parts.append("\(selection.totalTokens) tokens")
        } else if let tokenTotal = dto.tokenStats?.total {
            parts.append("\(tokenTotal) tokens")
        }
        return parts.isEmpty ? "snapshot" : parts.joined(separator: " • ")
    }

    private var status: ToolCardStatus {
        if item.toolIsError == true { return .failure }
        if let status = StoredToolCardPresentation.fromSummaryOnly(raw: item.toolResultJSON)?.status {
            return status
        }
        if dto != nil { return .success }
        return ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral)
    }

    var body: some View {
        ToolCardContainer(
            iconName: toolIcon(for: item.toolName),
            iconColor: ToolCardAccentResolver.color(for: item.toolName),
            title: "Context",
            detailText: nil,
            subtitle: inlineToolCardSummary(summary, detailText),
            status: status,
            timestamp: item.timestamp,
            isExpandable: toolResultHasPayload(item),
            isExpanded: $isExpanded
        ) {
            ToolMarkdownExpandedContent(item: item)
        }
    }
}
