import Foundation
import SwiftUI

// MARK: - Worktree Merge Tool Result Card

//
// Routed by `ToolCardRouter.resultView(for:)` whenever an Agent transcript
// shows a `manage_worktree` merge-op result. Decodes the structured
// `ManageWorktreeReplyDTO.merge` payload from `item.toolResultJSON` and surfaces the
// merge operation header, source/target endpoints, preflight summary, conflict
// or stale reason, and graph visualization in the expanded content area.

struct WorktreeMergeCardPresentation {
    let title: String
    let subtitle: String
    let detailText: String?
    let status: ToolCardStatus
}

enum WorktreeMergeCardPresentationBuilder {
    static func build(
        dto: ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO?,
        op: String? = nil,
        toolIsError: Bool?
    ) -> WorktreeMergeCardPresentation {
        if toolIsError == true {
            return WorktreeMergeCardPresentation(
                title: "Merge Worktree",
                subtitle: "failed",
                detailText: nil,
                status: .failure
            )
        }
        guard let dto else {
            return WorktreeMergeCardPresentation(
                title: "Merge Worktree",
                subtitle: "manage_worktree",
                detailText: nil,
                status: .neutral
            )
        }
        return WorktreeMergeCardPresentation(
            title: title(dto: dto, op: op),
            subtitle: subtitle(dto: dto),
            detailText: detailText(dto: dto),
            status: status(dto: dto)
        )
    }

    private static func title(dto: ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO, op: String?) -> String {
        let suffix: String? = switch (op ?? "").lowercased() {
        case "preview": "Preview"
        case "apply": "Apply"
        case "continue": "Continue"
        case "abort": "Abort"
        case "status": "Status"
        default: nil
        }
        guard let suffix else { return "Merge Worktree" }
        return "Merge Worktree • \(suffix)"
    }

    private static func subtitle(dto: ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO) -> String {
        var parts: [String] = []
        let sourceLabel = dto.source?.label ?? dto.source?.branch
        let targetLabel = dto.target?.label ?? dto.target?.branch
        if let sourceLabel, let targetLabel {
            parts.append("\(sourceLabel) → \(targetLabel)")
        } else if let targetLabel {
            parts.append("→ \(targetLabel)")
        }
        parts.append(dto.status)
        if let summary = dto.summary {
            parts.append("\(summary.commits)c · \(summary.files)f · +\(summary.insertions) -\(summary.deletions)")
        }
        return parts.joined(separator: " • ")
    }

    private static func detailText(dto: ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO) -> String? {
        if let error = dto.error, !error.isEmpty {
            return error
        }
        if let stale = dto.staleReason, !stale.isEmpty {
            return stale
        }
        if let conflicts = dto.conflictFiles, !conflicts.isEmpty {
            return "\(conflicts.count) conflicted file\(conflicts.count == 1 ? "" : "s")"
        }
        if let prediction = dto.preflight?.conflictPrediction,
           prediction.status == "conflicts",
           !prediction.files.isEmpty
        {
            return "Predicted conflicts in \(prediction.files.count) file\(prediction.files.count == 1 ? "" : "s")"
        }
        if let blockers = dto.preflight?.blockers, !blockers.isEmpty {
            return blockers.first?.message
        }
        if let next = dto.nextActions.first, !next.isEmpty {
            return next
        }
        return nil
    }

    private static func status(dto: ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO) -> ToolCardStatus {
        switch dto.status {
        case "completed", "aborted":
            .success
        case "failed":
            .failure
        case "blocked", "conflicted", "stale", "awaiting_commit":
            .warning
        case "awaiting_approval", "applying":
            .neutral
        case "preview":
            dto.preflight?.blocked == true ? .warning : .success
        default:
            .neutral
        }
    }
}

struct ToolResultWorktreeMergeCard: View {
    let item: AgentChatItem
    @State private var isExpanded = false

    private var reply: ToolResultDTOs.ManageWorktreeReplyDTO? {
        ToolJSON.decode(ToolResultDTOs.ManageWorktreeReplyDTO.self, from: item.toolResultJSON)
    }

    private var presentation: WorktreeMergeCardPresentation {
        WorktreeMergeCardPresentationBuilder.build(dto: reply?.merge, op: reply?.op, toolIsError: item.toolIsError)
    }

    var body: some View {
        ToolCardContainer(
            iconName: toolIcon(for: item.toolName),
            iconColor: ToolCardAccentResolver.color(for: item.toolName),
            title: presentation.title,
            detailText: presentation.detailText,
            subtitle: presentation.subtitle,
            status: presentation.status,
            timestamp: item.timestamp,
            isExpandable: toolResultHasPayload(item),
            isExpanded: $isExpanded
        ) {
            ToolMarkdownExpandedContent(item: item)
        }
    }
}
