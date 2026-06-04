import Foundation
import SwiftUI

struct ReadFileResultCard: View {
    let item: AgentChatItem
    @State private var isExpanded = false

    private var dto: ToolResultDTOs.ReadFileReply? {
        ToolJSON.decode(ToolResultDTOs.ReadFileReply.self, from: item.toolResultJSON)
    }

    /// Compact 1-line summary: "filename.swift • Lines 1-50 of 200"
    private var summary: String {
        if let summary = StoredToolCardPresentation.fromSummaryOnly(raw: item.toolResultJSON)?.inlineSubtitle {
            return summary
        }
        let args = ToolJSON.decodeArgs(ToolArgsDTOs.ReadFileArgs.self, from: item.toolArgsJSON)
        if dto == nil, args?.path == nil,
           let status = storageStatusSubtitle(for: item)
        {
            return status
        }
        let path = dto?.displayPath ?? args?.path ?? "file"
        let name = fileName(from: path)
        if let dto {
            return "\(name) • Lines \(dto.firstLine)-\(dto.lastLine) of \(dto.totalLines)"
        }
        return name
    }

    private var status: ToolCardStatus {
        if item.toolIsError == true { return .failure }
        if let dto, !dto.content.isEmpty || dto.totalLines > 0 { return .success }
        return ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral)
    }

    var body: some View {
        ToolCardContainer(
            iconName: toolIcon(for: item.toolName),
            iconColor: ToolCardAccentResolver.color(for: item.toolName),
            title: "Read File",
            subtitle: summary,
            status: status,
            timestamp: item.timestamp,
            isExpandable: toolResultHasPayload(item),
            isExpanded: $isExpanded
        ) {
            ToolMarkdownExpandedContent(item: item)
        }
    }
}

struct NativeReadResultCard: View {
    let item: AgentChatItem
    @State private var isExpanded = false

    private var args: ToolArgsDTOs.NativeReadArgs? {
        ToolJSON.decodeArgs(ToolArgsDTOs.NativeReadArgs.self, from: item.toolArgsJSON)
    }

    private var summary: String? {
        guard let path = args?.filePath ?? args?.path, !path.isEmpty else { return nil }
        return fileName(from: path)
    }

    private var status: ToolCardStatus {
        ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral)
    }

    var body: some View {
        ToolCardContainer(
            iconName: toolIcon(for: item.toolName),
            iconColor: ToolCardAccentResolver.color(for: item.toolName),
            title: "Read",
            subtitle: nonEmptyToolCardSummary(summary, fallbackStatusFor: item),
            status: status,
            timestamp: item.timestamp,
            isExpandable: toolResultHasPayload(item),
            isExpanded: $isExpanded
        ) {
            ToolMarkdownExpandedContent(item: item)
        }
    }
}

struct FileSearchResultCard: View {
    let item: AgentChatItem
    @State private var isExpanded = false

    private var dto: ToolResultDTOs.SearchResultDTO? {
        ToolJSON.decode(ToolResultDTOs.SearchResultDTO.self, from: item.toolResultJSON)
    }

    /// Compact summary: "\"query\" • 42 matches in 8 files"
    private var summary: String {
        if let summary = StoredToolCardPresentation.fromSummaryOnly(raw: item.toolResultJSON)?.inlineSubtitle {
            return summary
        }
        var parts: [String] = []
        if let pattern = ToolJSON.decodeArgs(ToolArgsDTOs.FileSearchArgs.self, from: item.toolArgsJSON)?.pattern,
           !pattern.isEmpty
        {
            parts.append("\"\(pattern)\"")
        }
        if let dto {
            var text = "\(dto.totalMatches) matches in \(dto.totalFiles) files"
            if dto.limitHit || (dto.sizeLimitHit ?? false) {
                text += " (limited)"
            }
            parts.append(text)
        }
        return parts.joined(separator: " • ")
    }

    private var status: ToolCardStatus {
        if item.toolIsError == true { return .failure }
        if let dto {
            if dto.errorMessage != nil { return .failure }
            if dto.limitHit || (dto.sizeLimitHit ?? false) { return .warning }
            if dto.totalMatches > 0 { return .success }
            return .neutral
        }
        return ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral)
    }

    var body: some View {
        ToolCardContainer(
            iconName: toolIcon(for: item.toolName),
            iconColor: ToolCardAccentResolver.color(for: item.toolName),
            title: "Search",
            subtitle: nonEmptyToolCardSummary(summary, fallbackStatusFor: item),
            status: status,
            timestamp: item.timestamp,
            isExpandable: toolResultHasPayload(item),
            isExpanded: $isExpanded
        ) {
            ToolMarkdownExpandedContent(item: item)
        }
    }
}

struct WebSearchResultCard: View {
    let item: AgentChatItem
    @State private var isExpanded = false

    private var presentation: AgentToolCardRenderSummary? {
        NativeToolCardPresentationBuilder.build(item: item, normalizedToolName: "search")
    }

    private var summary: String? {
        presentation?.inlineSummaryText ?? storageStatusSubtitle(for: item)
    }

    private var status: ToolCardStatus {
        if let presentation {
            return ToolCardStatus.fromRenderStatus(presentation.status)
        }
        return ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral)
    }

    var body: some View {
        ToolCardContainer(
            iconName: toolIcon(for: "search"),
            iconColor: ToolCardAccentResolver.color(for: "search"),
            title: "Web Search",
            subtitle: nonEmptyToolCardSummary(summary, fallbackStatusFor: item),
            status: status,
            timestamp: item.timestamp,
            isExpandable: toolResultHasPayload(item),
            isExpanded: $isExpanded
        ) {
            ToolMarkdownExpandedContent(item: item)
        }
    }
}

struct NativeToolResultCard: View {
    let item: AgentChatItem
    let normalizedToolName: String?
    @State private var isExpanded = false

    private var presentation: AgentToolCardRenderSummary? {
        NativeToolCardPresentationBuilder.build(item: item, normalizedToolName: normalizedToolName)
    }

    var body: some View {
        ToolCardContainer(
            iconName: toolIcon(for: normalizedToolName ?? item.toolName),
            iconColor: ToolCardAccentResolver.color(for: normalizedToolName ?? item.toolName),
            title: presentation?.title ?? toolDisplayName(for: normalizedToolName ?? item.toolName),
            subtitle: nonEmptyToolCardSummary(presentation?.inlineSummaryText, fallbackStatusFor: item),
            status: presentation.map { ToolCardStatus.fromRenderStatus($0.status) }
                ?? ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral),
            timestamp: item.timestamp,
            isExpandable: toolResultHasPayload(item),
            isExpanded: $isExpanded
        ) {
            ToolMarkdownExpandedContent(item: item)
        }
    }
}

enum NativeToolCardPresentationBuilder {
    static func build(item: AgentChatItem, normalizedToolName: String?) -> AgentToolCardRenderSummary? {
        let normalizedToolName = normalizedToolName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let summaryObject = ToolRawJSON.object(from: item.toolResultJSON),
           let renderSummary = AgentToolCardRenderSummary(summaryOnlyObject: summaryObject)
        {
            guard canTrustStoredSummary(renderSummary, normalizedToolName: normalizedToolName) else { return nil }
            return renderSummary
        }
        let rawObject = ToolRawJSON.object(from: item.toolResultJSON)
        let argsObject = ToolRawJSON.object(from: item.toolArgsJSON)
        let statusWord = statusWord(for: item)
        return AgentToolCardRenderSummaryBuilder.build(
            normalizedToolName: normalizedToolName,
            statusWord: statusWord,
            rawObject: rawObject,
            argsObject: argsObject,
            allowExistingSummaryOnly: true
        )
    }

    private static func canTrustStoredSummary(
        _ renderSummary: AgentToolCardRenderSummary,
        normalizedToolName: String?
    ) -> Bool {
        guard let normalizedToolName, renderSummary.toolName == normalizedToolName else { return false }
        if normalizedToolName == "search" { return true }
        return AgentToolCardRenderSummaryBuilder.isSafeNativeFallbackToolName(normalizedToolName)
    }

    private static func statusWord(for item: AgentChatItem) -> String {
        if item.toolIsError == true { return "failed" }
        if item.toolIsError == false { return "success" }
        guard let object = ToolRawJSON.object(from: item.toolResultJSON) else { return "unknown" }
        for key in ["status", "state", "outcome", "result"] {
            if let value = ToolRawJSON.string(object, key: key)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }
        return "unknown"
    }
}

struct FileActionResultCard: View {
    let item: AgentChatItem
    @State private var isExpanded = false

    private var dto: ToolResultDTOs.FileActionReply? {
        ToolJSON.decode(ToolResultDTOs.FileActionReply.self, from: item.toolResultJSON)
    }

    private var actionName: String? {
        if let action = dto?.action.trimmingCharacters(in: .whitespacesAndNewlines), !action.isEmpty {
            return action.lowercased()
        }
        if let action = ToolJSON.decodeArgs(ToolArgsDTOs.FileActionsArgs.self, from: item.toolArgsJSON)?.action?.trimmingCharacters(in: .whitespacesAndNewlines), !action.isEmpty {
            return action.lowercased()
        }
        return nil
    }

    private var iconColor: Color {
        switch actionName {
        case "create":
            BubbleColors.successGreen
        case "move":
            BubbleColors.toolNavigationAccent
        case "delete":
            BubbleColors.errorRed
        default:
            ToolCardAccentResolver.color(for: item.toolName)
        }
    }

    private var summary: String {
        if let dto {
            let action = dto.action.capitalized
            if let newPath = dto.newPath, !newPath.isEmpty {
                return "\(action): \(shortenPath(dto.path)) → \(shortenPath(newPath))"
            }
            return "\(action): \(shortenPath(dto.path))"
        }
        if let args = ToolJSON.decodeArgs(ToolArgsDTOs.FileActionsArgs.self, from: item.toolArgsJSON),
           let action = args.action,
           let path = args.path
        {
            if let newPath = args.newPath, !newPath.isEmpty {
                return "\(action.capitalized): \(shortenPath(path)) → \(shortenPath(newPath))"
            }
            return "\(action.capitalized): \(shortenPath(path))"
        }
        return ""
    }

    private var status: ToolCardStatus {
        if item.toolIsError == true { return .failure }
        if let dto {
            switch dto.status.lowercased() {
            case "ok", "success": return .success
            case "warning", "partial": return .warning
            case "error", "failed": return .failure
            default: break
            }
        }
        return ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral)
    }

    var body: some View {
        ToolCardContainer(
            iconName: toolIcon(for: item.toolName),
            iconColor: iconColor,
            title: "File Action",
            subtitle: summary,
            status: status,
            timestamp: item.timestamp,
            isExpandable: toolResultHasPayload(item),
            isExpanded: $isExpanded
        ) {
            ToolMarkdownExpandedContent(item: item)
        }
    }
}
