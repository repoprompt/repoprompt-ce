import Foundation
import SwiftUI

private func oracleToolResultTicket(from raw: String?) -> ToolResultDTOs.LongRunningJobTicketDTO? {
    guard let raw else { return nil }
    // Completed jobs may also carry a reply. A direct ticket owns its job state;
    // a direct reply must not be displaced by a conflicting nested ticket echo.
    let data: Data?
    if let direct = ToolResultDTOs.LongRunningJobTicketDTO.validatedJSONData(from: raw) {
        data = direct
    } else if ToolResultDTOs.ChatSendDTO.nativeOracleReplyJSONData(from: raw) == Data(raw.utf8) {
        return nil
    } else {
        data = ToolResultDTOs.LongRunningJobTicketDTO.nativeJSONData(from: raw)
    }
    guard let data else { return nil }
    return try? JSONDecoder().decode(ToolResultDTOs.LongRunningJobTicketDTO.self, from: data)
}

func oracleToolResultPopoverUserInfo(
    item: AgentChatItem,
    openContext: AgentOracleOpenContext?
) -> [AnyHashable: Any]? {
    if let ticket = oracleToolResultTicket(from: item.toolResultJSON) {
        guard let openContext, openContext.workspaceID != nil,
              let tabID = ticket.job.contextID, openContext.tabID == tabID,
              ticket.job.status == .completed || ticket.job.status == .failed || ticket.job.status == .cancelled
        else { return nil }
        let reply = ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: item.toolResultJSON)
        let chatID = ticket.job.status == .completed ? reply?.chatID ?? ticket.job.chatID : ticket.job.chatID
        return AgentOracleToolRouting.operationPopoverUserInfo(
            openContext: openContext,
            chatID: chatID,
            presentation: ticket.job.status == .completed ? .standard : .generatedAnswerReadOnly
        )
    }
    let chatID = AgentOracleAuthoritativeChatIDPolicy.extract(fromSerializedJSON: item.toolResultJSON)
    return AgentOracleToolRouting.operationPopoverUserInfo(
        openContext: openContext,
        chatID: chatID
    )
}

struct ChatSendResultCard: View {
    let item: AgentChatItem
    let oracleOpenContext: AgentOracleOpenContext?

    private var isOracleTool: Bool {
        let toolName = (normalizedToolCardName(item.toolName) ?? "").lowercased()
        return toolName == "ask_oracle" || toolName == "oracle_send"
    }

    private var dto: ToolResultDTOs.ChatSendDTO? {
        ToolJSON.decode(ToolResultDTOs.ChatSendDTO.self, from: item.toolResultJSON)
    }

    private var ticket: ToolResultDTOs.LongRunningJobTicketDTO? {
        isOracleTool ? oracleToolResultTicket(from: item.toolResultJSON) : nil
    }

    private var laneCoverage: OracleLaneCoverage? {
        isOracleTool ? OracleLaneCoverage(lanes: dto?.oracleResults, oracleCount: dto?.oracleCount) : nil
    }

    /// Compact summary showing mode and a small amount of result context
    var summary: String {
        let ticket = ticket
        let observationPrefix = ticket != nil && item.toolIsError == true ? "Observation failed · " : ""
        if let ticket, ticket.job.status != .completed {
            return observationPrefix + longRunningJobTicketObservationLabel(ticket)
        }
        guard let dto else { return "" }
        var parts: [String] = []
        if let mode = dto.mode { parts.append(mode) }
        if let laneCoverage {
            parts.append(laneCoverage.summaryText)
        } else if let chatID = dto.chatID, !chatID.isEmpty, parts.isEmpty || dto.diffs?.isEmpty != false {
            parts.append(chatID)
        }
        if let diffs = dto.diffs, !diffs.isEmpty {
            parts.append("\(diffs.count) diffs")
        }
        let replySummary = parts.joined(separator: " • ")
        guard let ticket else { return replySummary }
        let detail = replySummary.isEmpty ? "" : " · \(replySummary)"
        return observationPrefix + "Job completed\(detail) · \(ticket.jobID.uuidString)"
    }

    var status: ToolCardStatus {
        if let ticket {
            // A successful control observation is not a completed job. No live job
            // binding exists here, so even a fresh nonterminal snapshot is neutral.
            if item.toolIsError == true { return .failure }
            switch ticket.job.status {
            case .failed, .cancelled: return .failure
            case .expired: return .warning
            case .running, .cancelling, .unknown: return .neutral
            case .completed: break
            }
        }
        if isOracleTool, dto?.status == "partial_failure" { return .warning }
        if item.toolIsError == true { return .failure }
        if let dto {
            if let errors = dto.errors, !errors.isEmpty { return .failure }
            // A failed primary determines the canonical group outcome even when
            // additional lanes completed. Coverage still supplies the subtitle.
            if isOracleTool, dto.status == "failed" { return .failure }
            if let coverageStatus = laneCoverage?.cardStatus { return coverageStatus }
            // Invalid lane identities suppress the fraction, not the group's known warning.
            if isOracleTool, dto.status == "partial_failure" || dto.status == "warning" { return .warning }
            if dto.response == nil || dto.response?.isEmpty == true,
               let diffs = dto.diffs,
               !diffs.isEmpty
            {
                return .warning
            }
            return .success
        }
        return ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral)
    }

    private var onTap: (() -> Void)? {
        guard let userInfo = oracleToolResultPopoverUserInfo(
            item: item,
            openContext: oracleOpenContext
        ) else { return nil }
        return {
            NotificationCenter.default.post(name: .showAgentOraclePopover, object: nil, userInfo: userInfo)
        }
    }

    var body: some View {
        StaticToolCardContainer(
            iconName: toolIcon(for: item.toolName),
            iconColor: ToolCardAccentResolver.color(for: item.toolName),
            title: isOracleTool ? (ticket == nil ? "Oracle" : "Oracle observation") : "Chat",
            subtitle: summary,
            status: status,
            timestamp: item.timestamp,
            onTap: onTap
        ) {
            EmptyView()
        }
    }
}

struct ChatsResultCard: View {
    let item: AgentChatItem
    @State private var isExpanded = false

    private var dto: ChatsReplyDTO? {
        ToolJSON.decode(ChatsReplyDTO.self, from: item.toolResultJSON)
    }

    private var detailText: String? {
        if let chats = dto?.chats, !chats.isEmpty {
            let visible = chats.prefix(2).compactMap { chat -> String? in
                let trimmed = chat.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : chat.id
            }
            guard !visible.isEmpty else { return nil }
            var parts = visible
            if chats.count > visible.count {
                parts.append("(+\(chats.count - visible.count) more)")
            }
            return parts.joined(separator: " • ")
        }
        return nil
    }

    private var summary: String {
        if let dto {
            if dto.action?.lowercased() == "log" {
                let chatID = dto.chatID ?? "chat"
                let messageCount = dto.messages?.count ?? 0
                return "\(chatID) • \(messageCount) messages"
            }
            if let count = dto.chats?.count {
                return "\(count) chats"
            }
        }
        if let action = ToolJSON.decodeArgs(ToolArgsDTOs.ChatsArgs.self, from: item.toolArgsJSON)?.action,
           !action.isEmpty
        {
            return action
        }
        return ""
    }

    private var status: ToolCardStatus {
        if item.toolIsError == true { return .failure }
        if let dto {
            if dto.action?.lowercased() == "log" {
                return .success
            }
            if dto.chats != nil {
                return .success
            }
        }
        return ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral)
    }

    var body: some View {
        let normalizedName = normalizedToolCardName(item.toolName)?.lowercased()
        let title = (normalizedName == "oracle_chat_log") ? "Oracle Log" : "Chats"
        ToolCardContainer(
            iconName: toolIcon(for: item.toolName),
            iconColor: ToolCardAccentResolver.color(for: item.toolName),
            title: title,
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

struct ListModelsResultCard: View {
    let item: AgentChatItem
    @State private var isExpanded = false

    private var dto: ToolResultDTOs.ListModelsReply? {
        ToolJSON.decode(ToolResultDTOs.ListModelsReply.self, from: item.toolResultJSON)
    }

    private var detailText: String? {
        guard let models = dto?.models, !models.isEmpty else { return nil }
        let visible = models.prefix(2).map(\.name)
        var parts = visible
        if models.count > visible.count {
            parts.append("(+\(models.count - visible.count) more)")
        }
        return parts.joined(separator: " • ")
    }

    private var summary: String {
        guard let dto else { return "" }
        return "\(dto.total) models"
    }

    private var status: ToolCardStatus {
        if item.toolIsError == true { return .failure }
        if let dto {
            return dto.total > 0 ? .success : .neutral
        }
        return ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral)
    }

    var body: some View {
        ToolCardContainer(
            iconName: toolIcon(for: item.toolName),
            iconColor: ToolCardAccentResolver.color(for: item.toolName),
            title: "Models",
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

struct ManageWorkspacesResultCard: View {
    let item: AgentChatItem
    @State private var isExpanded = false

    private var dto: ManageWorkspacesResponse? {
        ToolJSON.decode(ManageWorkspacesResponse.self, from: item.toolResultJSON)
    }

    private var detailText: String? {
        guard let dto else { return nil }
        if let workspaces = dto.workspaces, !workspaces.isEmpty {
            let visible = workspaces.prefix(2).map(\.name)
            var parts = visible
            if workspaces.count > visible.count {
                parts.append("(+\(workspaces.count - visible.count) more)")
            }
            return parts.joined(separator: " • ")
        }
        if let tabs = dto.tabs, !tabs.isEmpty {
            let visible = tabs.prefix(2).map(\.name)
            var parts = visible
            if tabs.count > visible.count {
                parts.append("(+\(tabs.count - visible.count) more)")
            }
            return parts.joined(separator: " • ")
        }
        return nil
    }

    private var headerStatusText: String? {
        nil
    }

    private var summary: String {
        if let dto {
            var parts: [String] = [dto.action]
            if let workspaces = dto.workspaces {
                parts.append("\(workspaces.count) workspaces")
            }
            if let tabs = dto.tabs {
                parts.append("\(tabs.count) tabs")
            }
            if let windowID = dto.windowID {
                parts.append("window \(windowID)")
            }
            if let closedWindowID = dto.closedWindowID {
                parts.append("closed \(closedWindowID)")
            }
            return parts.joined(separator: " • ")
        }
        if let action = ToolJSON.decodeArgs(ToolArgsDTOs.ManageWorkspacesArgs.self, from: item.toolArgsJSON)?.action {
            return action
        }
        return ""
    }

    private var status: ToolCardStatus {
        if item.toolIsError == true { return .failure }
        if let dto, let status = dto.status, let mapped = ToolResultStatusResolver.mapStatusWord(status) {
            return mapped
        }
        return ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral)
    }

    var body: some View {
        ToolCardContainer(
            iconName: toolIcon(for: item.toolName),
            iconColor: ToolCardAccentResolver.color(for: item.toolName),
            title: "Workspaces",
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

private struct ChatsReplyDTO: Decodable {
    let action: String?
    let chats: [ChatSummaryDTO]?
    let chatID: String?
    let messages: [ChatMessageDTO]?

    enum CodingKeys: String, CodingKey {
        case action
        case chats
        case chatID = "chat_id"
        case messages
    }
}

private struct ChatSummaryDTO: Decodable {
    let id: String?
    let name: String?
    let messageCount: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case messageCount = "message_count"
    }
}

private struct ChatMessageDTO: Decodable {}
