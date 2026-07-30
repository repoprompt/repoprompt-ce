import Foundation
import SwiftUI

struct GitCardPresentation {
    let subtitle: String
    let detailText: String?
    let status: ToolCardStatus
}

enum GitCardPresentationBuilder {
    static func build(dto: ToolResultDTOs.GitToolReplyDTO?, args: ToolArgsDTOs.GitArgs?, toolIsError: Bool?) -> GitCardPresentation {
        if toolIsError == true {
            return GitCardPresentation(
                subtitle: fallbackSubtitle(args: args),
                detailText: fallbackDetailText(args: args),
                status: .failure
            )
        }
        guard let dto else {
            return GitCardPresentation(
                subtitle: fallbackSubtitle(args: args),
                detailText: fallbackDetailText(args: args),
                status: .neutral
            )
        }

        return GitCardPresentation(
            subtitle: subtitle(dto: dto, args: args),
            detailText: detailText(dto: dto, args: args),
            status: status(dto: dto)
        )
    }

    private static func status(dto: ToolResultDTOs.GitToolReplyDTO) -> ToolCardStatus {
        if hasText(dto.error) {
            return .failure
        }
        if hasText(dto.emptyReason) || hasText(dto.warning) || isLimited(dto) {
            return .warning
        }
        return .success
    }

    private static func subtitle(dto: ToolResultDTOs.GitToolReplyDTO, args: ToolArgsDTOs.GitArgs?) -> String {
        let op = normalizedOp(dto.op) ?? normalizedOp(args?.op) ?? "git"
        switch op {
        case "status":
            return join(op, statusPrimarySummary(dto) ?? repoCountText(dto.repos))
        case "diff":
            return join(op, preferredDiffSummary(dto) ?? args?.compare)
        case "log":
            if let commits = dto.log?.commits {
                if commits.count == 1, let first = commits.first {
                    return join(op, first.shortSha)
                }
                return join(op, "\(commits.count) commits")
            }
            return join(op, repoCountText(dto.repos))
        case "show":
            if let show = dto.show {
                return join(op, show.shortSha)
            }
            return join(op, repoCountText(dto.repos))
        case "blame":
            if let blame = dto.blame {
                return join(op, shortenPath(blame.path))
            }
            return join(op, repoCountText(dto.repos))
        default:
            if let oneliner = preferredDiffSummary(dto) {
                return join(op, oneliner)
            }
            return join(op, repoCountText(dto.repos) ?? args?.compare)
        }
    }

    private static func detailText(dto: ToolResultDTOs.GitToolReplyDTO, args: ToolArgsDTOs.GitArgs?) -> String? {
        let op = normalizedOp(dto.op) ?? normalizedOp(args?.op)
        switch op {
        case "status":
            return statusDetailText(dto)
        case "diff":
            return diffDetailText(dto: dto, args: args)
        case "log":
            return logDetailText(dto)
        case "show":
            return showDetailText(dto)
        case "blame":
            return blameDetailText(dto)
        default:
            return fallbackDetailText(dto: dto, args: args)
        }
    }

    private static func statusPrimarySummary(_ dto: ToolResultDTOs.GitToolReplyDTO) -> String? {
        if let branch = trimmed(dto.status?.branch) {
            return branch
        }
        return repoCountText(dto.repos)
    }

    private static func statusDetailText(_ dto: ToolResultDTOs.GitToolReplyDTO) -> String? {
        if let status = dto.status {
            var parts: [String] = []
            if let ahead = status.ahead, let behind = status.behind, ahead > 0 || behind > 0 {
                parts.append("+\(ahead) -\(behind)")
            }
            if let upstream = trimmed(status.upstream) {
                parts.append(upstream)
            }
            if !status.staged.isEmpty {
                parts.append("\(status.staged.count) staged")
            }
            if !status.modified.isEmpty {
                parts.append("\(status.modified.count) modified")
            }
            if !status.untracked.isEmpty {
                parts.append("\(status.untracked.count) untracked")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " • ")
        }
        return repoPreviewText(dto.repos)
    }

    private static func diffDetailText(dto: ToolResultDTOs.GitToolReplyDTO, args: ToolArgsDTOs.GitArgs?) -> String? {
        var parts: [String] = []
        if let compare = trimmed(dto.inputs?.compare ?? args?.compare) {
            parts.append(compare)
        }
        if let scope = trimmed(dto.inputs?.scope) {
            parts.append(scope)
        }
        if let detail = trimmed(dto.diff?.detail ?? args?.detail) {
            parts.append(detail)
        }
        if let branch = trimmed(dto.worktree?.worktreeBranch), parts.count < 3 {
            parts.append(branch)
        }
        if let preview = repoPreviewText(dto.repos), parts.isEmpty {
            parts.append(preview)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private static func logDetailText(_ dto: ToolResultDTOs.GitToolReplyDTO) -> String? {
        if let commits = dto.log?.commits, let first = commits.first {
            var parts: [String] = []
            parts.append("latest \(first.shortSha)")
            parts.append(first.author)
            if commits.count == 1 {
                parts.append(summaryTotalsText(files: first.filesChanged, insertions: first.insertions, deletions: first.deletions))
            }
            return parts.joined(separator: " • ")
        }
        return repoPreviewText(dto.repos)
    }

    private static func showDetailText(_ dto: ToolResultDTOs.GitToolReplyDTO) -> String? {
        if let show = dto.show {
            var parts: [String] = []
            if let message = trimmed(show.message) {
                parts.append(shortenedMessage(message))
            }
            parts.append(summaryTotalsText(files: show.totals.files, insertions: show.totals.insertions, deletions: show.totals.deletions))
            return parts.joined(separator: " • ")
        }
        return repoPreviewText(dto.repos)
    }

    private static func blameDetailText(_ dto: ToolResultDTOs.GitToolReplyDTO) -> String? {
        if let blame = dto.blame {
            var parts = ["\(blame.lines.count) lines"]
            let authors = Set(blame.lines.map(\.author).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            if !authors.isEmpty {
                parts.append("\(authors.count) authors")
            }
            return parts.joined(separator: " • ")
        }
        return repoPreviewText(dto.repos)
    }

    private static func fallbackSubtitle(args: ToolArgsDTOs.GitArgs?) -> String {
        let op = normalizedOp(args?.op) ?? "git"
        return join(op, trimmed(args?.compare))
    }

    private static func fallbackDetailText(dto: ToolResultDTOs.GitToolReplyDTO? = nil, args: ToolArgsDTOs.GitArgs?) -> String? {
        var parts: [String] = []
        if let compare = trimmed(dto?.inputs?.compare ?? args?.compare) {
            parts.append(compare)
        }
        if let detail = trimmed(dto?.diff?.detail ?? args?.detail) {
            parts.append(detail)
        }
        if let branch = trimmed(dto?.worktree?.worktreeBranch), parts.count < 3 {
            parts.append(branch)
        }
        if let preview = repoPreviewText(dto?.repos), parts.isEmpty {
            parts.append(preview)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private static func preferredDiffSummary(_ dto: ToolResultDTOs.GitToolReplyDTO) -> String? {
        trimmed(dto.aggregate?.oneliner)
            ?? trimmed(dto.diff?.oneliner)
            ?? trimmed(dto.oneliner)
    }

    private static func repoCountText(_ repos: [ToolResultDTOs.GitToolReplyDTO.RepoResultDTO]?) -> String? {
        guard let repos, repos.count > 1 else { return nil }
        return "\(repos.count) repos"
    }

    private static func repoPreviewText(_ repos: [ToolResultDTOs.GitToolReplyDTO.RepoResultDTO]?) -> String? {
        guard let repos, !repos.isEmpty else { return nil }
        let visible = repos.prefix(2).compactMap { trimmed($0.repoName) ?? trimmed($0.worktree?.worktreeBranch) }
        guard !visible.isEmpty else { return repoCountText(repos) }
        var parts = visible
        if repos.count > visible.count {
            parts.append("(+\(repos.count - visible.count) more)")
        }
        return parts.joined(separator: " • ")
    }

    private static func summaryTotalsText(files: Int, insertions: Int, deletions: Int) -> String {
        "\(files) files (+\(insertions) -\(deletions))"
    }

    private static func shortenedMessage(_ message: String) -> String {
        if message.count <= 48 {
            return message
        }
        return String(message.prefix(45)) + "…"
    }

    private static func normalizedOp(_ value: String?) -> String? {
        trimmed(value)?.lowercased()
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func hasText(_ value: String?) -> Bool {
        trimmed(value) != nil
    }

    private static func isLimited(_ dto: ToolResultDTOs.GitToolReplyDTO) -> Bool {
        dto.diff?.truncated == true || dto.inline?.truncated == true
    }

    private static func join(_ lhs: String, _ rhs: String?) -> String {
        guard let rhs = trimmed(rhs) else { return lhs }
        return "\(lhs) • \(rhs)"
    }
}

struct GitResultCard: View {
    let item: AgentChatItem
    @State private var isExpanded = false

    private var dto: ToolResultDTOs.GitToolReplyDTO? {
        ToolJSON.decode(ToolResultDTOs.GitToolReplyDTO.self, from: item.toolResultJSON)
    }

    private var args: ToolArgsDTOs.GitArgs? {
        ToolJSON.decodeArgs(ToolArgsDTOs.GitArgs.self, from: item.toolArgsJSON)
    }

    private var presentation: GitCardPresentation {
        if let stored = StoredToolCardPresentation.fromSummaryOnly(raw: item.toolResultJSON) {
            return GitCardPresentation(
                subtitle: stored.subtitle ?? stored.inlineSubtitle ?? "git",
                detailText: stored.detailText,
                status: item.toolIsError == true ? .failure : (stored.status ?? ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral))
            )
        }
        return GitCardPresentationBuilder.build(dto: dto, args: args, toolIsError: item.toolIsError)
    }

    var body: some View {
        ToolCardContainer(
            iconName: toolIcon(for: item.toolName),
            iconColor: ToolCardAccentResolver.color(for: item.toolName),
            title: "Git",
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
