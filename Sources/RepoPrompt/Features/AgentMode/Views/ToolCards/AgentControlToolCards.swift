import SwiftUI

struct AgentReasoningEffortBadgePresentation: Equatable {
    let rawValue: String
    let displayLabel: String

    init?(rawValue: String?) {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty
        else {
            return nil
        }
        self.rawValue = rawValue
        displayLabel = CodexReasoningEffort.parse(rawValue)?.displayName
            ?? Self.readableFallbackLabel(from: rawValue)
    }

    private static func readableFallbackLabel(from rawValue: String) -> String {
        let tokens = rawValue
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { token in
                let value = String(token)
                return value.isEmpty ? value : value.prefix(1).uppercased() + value.dropFirst().lowercased()
            }
        let label = tokens.joined(separator: " ")
        return label.isEmpty ? rawValue : label
    }
}

struct AgentRunCardPresentation: Equatable {
    let sessionID: UUID?
    let statusWord: String?
    let statusText: String?
    let sessionNameOrID: String?
    let agentName: String?
    let model: String?
    let workflowLabel: String?
    let reasoningBadge: AgentReasoningEffortBadgePresentation?
    let assistantText: String?
    let interactionKind: String?
    let interactionPrompt: String?
    let deliveryRaw: String?
    let op: String

    init?(resultObject: [String: Any], args: ToolArgsDTOs.AgentRunArgs? = nil, opOverride: String? = nil) {
        let sessionObject = resultObject["session"] as? [String: Any]
        let agentObject = resultObject["agent"] as? [String: Any]
        let interactionObject = resultObject["interaction"] as? [String: Any]
        let metaObject = resultObject["_meta"] as? [String: Any]
        sessionID = Self.sessionID(from: resultObject, args: args)
        statusWord = (resultObject["status"] as? String)?.nonEmpty
        statusText = (resultObject["status_text"] as? String)?.nonEmpty
        sessionNameOrID = Self.sessionNameOrID(sessionObject: sessionObject, args: args)
        agentName = (agentObject?["name"] as? String)?.nonEmpty
            ?? (agentObject?["id"] as? String)?.nonEmpty
            ?? args?.agent?.nonEmpty
        model = (agentObject?["model"] as? String)?.nonEmpty ?? args?.model?.nonEmpty
        workflowLabel = (resultObject["workflow_name"] as? String)?.nonEmpty
            ?? args?.workflowName?.nonEmpty
            ?? (resultObject["workflow_id"] as? String)?.nonEmpty
            ?? args?.workflowID?.nonEmpty
        let rawReasoningEffort = (agentObject?["reasoning_effort"] as? String)?.nonEmpty ?? args?.reasoningEffort?.nonEmpty
        reasoningBadge = AgentReasoningEffortBadgePresentation(rawValue: rawReasoningEffort)
        assistantText = (resultObject["assistant_text"] as? String)?.nonEmpty
        interactionKind = (interactionObject?["kind"] as? String)?.nonEmpty
        interactionPrompt = (interactionObject?["prompt"] as? String)?.nonEmpty
        deliveryRaw = (metaObject?["delivery"] as? String)?.nonEmpty
        op = opOverride?.lowercased() ?? args?.op?.lowercased() ?? "start"
    }

    var visualStatus: ToolCardStatus {
        switch statusWord?.lowercased() {
        case "running":
            // The session is still running, but the tool call itself completed.
            // For fire-and-forget ops (steer, respond, start, poll, cancel) a
            // session status of "running" means the action succeeded — show
            // success instead of a spinner so cards don't appear stuck.
            switch op {
            case "wait":
                // wait is expected to block until a terminal/interesting state,
                // so "running" here is unusual — show neutral rather than a
                // misleading spinner.
                .neutral
            default:
                .success
            }
        case "waiting_for_input":
            .warning
        case "cancelled", "expired":
            .warning
        case "completed":
            .success
        case "failed":
            .failure
        default:
            .neutral
        }
    }

    var subtitle: String? {
        let parts = [statusLabel, interactionLabel, workflowLabel, sessionNameOrID, agentName, model]
            .compactMap(\.self)
        if !parts.isEmpty {
            return parts.joined(separator: " • ")
        }
        return assistantText?.singleLineSummary
    }

    var detailText: String? {
        nil
    }

    private var isTerminal: Bool {
        switch statusWord?.lowercased() {
        case "completed", "failed", "cancelled", "expired":
            true
        default:
            false
        }
    }

    private var statusLabel: String? {
        guard let statusWord else { return nil }
        return AgentRunMCPSnapshot.Status(rawValue: statusWord)?.displayLabel
    }

    private var interactionLabel: String? {
        guard let interactionKind else { return nil }
        return AgentRunMCPSnapshot.Interaction.Kind(rawValue: interactionKind)?.displayLabel
    }

    private var deliveryExplanation: String? {
        guard let deliveryRaw else { return nil }
        return AgentModeViewModel.MCPInstructionDispatch(rawValue: deliveryRaw)?.deliveryExplanation
    }

    private static func sessionID(from resultObject: [String: Any], args: ToolArgsDTOs.AgentRunArgs?) -> UUID? {
        if let rawSessionID = (resultObject["session_id"] as? String)?.nonEmpty {
            return UUID(uuidString: rawSessionID)
        }
        if let rawSessionID = ((resultObject["session"] as? [String: Any])?["id"] as? String)?.nonEmpty {
            return UUID(uuidString: rawSessionID)
        }
        if let rawSessionID = args?.sessionID?.nonEmpty {
            return UUID(uuidString: rawSessionID)
        }
        return nil
    }

    private static func sessionNameOrID(sessionObject: [String: Any]?, args: ToolArgsDTOs.AgentRunArgs?) -> String? {
        if let name = (sessionObject?["name"] as? String)?.nonEmpty {
            return name
        }
        if let id = (sessionObject?["id"] as? String)?.nonEmpty {
            return id
        }
        if let name = args?.sessionName?.nonEmpty {
            return name
        }
        if let id = args?.sessionID?.nonEmpty {
            return id
        }
        return nil
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }

    var singleLineSummary: String? {
        let normalized = replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

private struct AgentReasoningEffortHeaderTrailingView: View {
    let badge: AgentReasoningEffortBadgePresentation
    let timestamp: Date?

    var body: some View {
        HStack(spacing: 6) {
            AgentReasoningEffortBadge(presentation: badge)
            if let timestamp {
                MessageTimestampText(date: timestamp)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
        .fixedSize()
    }
}

private struct AgentReasoningEffortBadge: View {
    let presentation: AgentReasoningEffortBadgePresentation

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 8, weight: .semibold))
            Text(presentation.displayLabel)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.12))
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reasoning effort \(presentation.displayLabel)")
    }
}

struct AgentRunResultCard: View {
    let item: AgentChatItem
    @State private var isExpanded = false

    private var args: ToolArgsDTOs.AgentRunArgs? {
        ToolJSON.decodeArgs(ToolArgsDTOs.AgentRunArgs.self, from: item.toolArgsJSON)
    }

    private var op: String {
        args?.op?.lowercased() ?? "start"
    }

    private var resultObject: [String: Any]? {
        ToolJSON.structuredResultObject(from: item.toolResultJSON)
    }

    private var presentation: AgentRunCardPresentation? {
        resultObject.flatMap { AgentRunCardPresentation(resultObject: $0, args: args) }
    }

    private var title: String {
        switch op {
        case "start": "Start Run"
        case "poll": "Poll Run"
        case "wait": "Wait for Run"
        case "cancel": "Cancel Run"
        case "steer": "Steer Run"
        case "respond": "Respond to Run"
        default: "Agent Run"
        }
    }

    private var status: ToolCardStatus {
        presentation?.visualStatus
            ?? ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral)
    }

    private var hasExpandablePayload: Bool {
        guard let raw = item.toolResultJSON?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return false
        }
        if let object = ToolRawJSON.object(from: item.toolResultJSON),
           ToolRawJSON.bool(object, key: "summary_only") == true
        {
            return false
        }
        return true
    }

    private var headerTrailingView: AnyView? {
        presentation?.reasoningBadge.map {
            AnyView(AgentReasoningEffortHeaderTrailingView(badge: $0, timestamp: item.timestamp))
        }
    }

    var body: some View {
        ToolCardContainer(
            iconName: "play.circle",
            iconColor: ToolCardAccentResolver.color(for: "agent_run"),
            title: title,
            detailText: nil,
            subtitle: presentation?.subtitle,
            status: status,
            timestamp: item.timestamp,
            headerTrailingView: headerTrailingView,
            isExpandable: hasExpandablePayload,
            isExpanded: $isExpanded
        ) {
            ToolMarkdownExpandedContent(item: item)
        }
    }
}

private struct AgentExploreBatchStartPresentation {
    let startedCount: Int
    let runningCount: Int
    let visualStatus: ToolCardStatus

    init?(resultObject: [String: Any]) {
        guard let start = resultObject["start"] as? [String: Any],
              (start["mode"] as? String) == "many"
        else {
            return nil
        }
        let snapshots = resultObject["snapshots"] as? [[String: Any]] ?? []
        let sessionIDs = resultObject["session_ids"] as? [String] ?? []
        startedCount = (start["started_count"] as? Int) ?? sessionIDs.count
        runningCount = (start["running_session_ids"] as? [String])?.count
            ?? snapshots.count(where: { ($0["status"] as? String) == "running" })
        let statuses = snapshots.compactMap { ($0["status"] as? String)?.lowercased() }
        if statuses.contains("failed") {
            visualStatus = .failure
        } else if statuses.contains(where: { ["waiting_for_input", "expired", "cancelled"].contains($0) }) {
            visualStatus = .warning
        } else if !snapshots.isEmpty || startedCount > 0 {
            visualStatus = .success
        } else {
            visualStatus = .neutral
        }
    }

    var subtitle: String {
        "Started \(startedCount) explores • \(runningCount) running"
    }
}

struct AgentExploreResultCard: View {
    let item: AgentChatItem
    @State private var isExpanded = false

    private var args: ToolArgsDTOs.AgentExploreArgs? {
        ToolJSON.decodeArgs(ToolArgsDTOs.AgentExploreArgs.self, from: item.toolArgsJSON)
    }

    private var op: String {
        args?.op?.lowercased() ?? "start"
    }

    private var resultObject: [String: Any]? {
        ToolJSON.structuredResultObject(from: item.toolResultJSON)
    }

    private var presentation: AgentRunCardPresentation? {
        resultObject.flatMap {
            AgentRunCardPresentation(
                resultObject: $0,
                args: nil,
                opOverride: op
            )
        }
    }

    private var batchPresentation: AgentExploreBatchStartPresentation? {
        resultObject.flatMap { AgentExploreBatchStartPresentation(resultObject: $0) }
    }

    private var title: String {
        switch op {
        case "start": "Start Explore"
        case "poll": "Poll Explore"
        case "wait": "Wait for Explore"
        case "cancel": "Cancel Explore"
        default: "Agent Explore"
        }
    }

    private var status: ToolCardStatus {
        batchPresentation?.visualStatus
            ?? presentation?.visualStatus
            ?? ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral)
    }

    private var hasExpandablePayload: Bool {
        guard let raw = item.toolResultJSON?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return false
        }
        if let object = ToolRawJSON.object(from: item.toolResultJSON),
           ToolRawJSON.bool(object, key: "summary_only") == true
        {
            return false
        }
        return true
    }

    private var headerTrailingView: AnyView? {
        presentation?.reasoningBadge.map {
            AnyView(AgentReasoningEffortHeaderTrailingView(badge: $0, timestamp: item.timestamp))
        }
    }

    var body: some View {
        ToolCardContainer(
            iconName: "magnifyingglass.circle",
            iconColor: ToolCardAccentResolver.color(for: "agent_explore"),
            title: title,
            detailText: nil,
            subtitle: batchPresentation?.subtitle ?? presentation?.subtitle,
            status: status,
            timestamp: item.timestamp,
            headerTrailingView: headerTrailingView,
            isExpandable: hasExpandablePayload,
            isExpanded: $isExpanded
        ) {
            ToolMarkdownExpandedContent(item: item)
        }
    }
}

struct AgentManageResultCard: View {
    let item: AgentChatItem
    @State private var isExpanded = false

    private var args: ToolArgsDTOs.AgentManageArgs? {
        ToolJSON.decodeArgs(ToolArgsDTOs.AgentManageArgs.self, from: item.toolArgsJSON)
    }

    private var op: String {
        args?.op?.lowercased() ?? "list_sessions"
    }

    private var resultObject: [String: Any]? {
        ToolJSON.structuredResultObject(from: item.toolResultJSON)
    }

    private var title: String {
        switch op {
        case "list_agents": "List Agents"
        case "list_sessions": "List Sessions"
        case "get_log": "Session Log"
        case "create_session": "Create Session"
        case "resume_session": "Resume Session"
        case "stop_session": "Stop Session"
        case "cleanup_sessions": "Cleanup Sessions"
        case "list_workflows": "List Workflows"
        default: "Agent Manage"
        }
    }

    private var status: ToolCardStatus {
        ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .success)
    }

    private var subtitle: String? {
        guard let resultObject else { return nil }
        switch op {
        case "list_agents":
            if let agents = resultObject["agents"] as? [[String: Any]] {
                return "\(agents.count) agents"
            }
        case "list_sessions":
            if let sessions = resultObject["sessions"] as? [[String: Any]] {
                return "\(sessions.count) sessions"
            }
        case "get_log":
            if let returned = resultObject["returned_turn_count"] as? Int,
               let total = resultObject["total_turns"] as? Int
            {
                return "\(returned)/\(total) turns"
            }
        case "create_session", "resume_session", "stop_session":
            return (resultObject["name"] as? String)?.nonEmpty
        case "cleanup_sessions":
            let deleted = resultObject["deleted_count"] as? Int ?? 0
            let skipped = resultObject["skipped_count"] as? Int ?? 0
            return "\(deleted) deleted, \(skipped) skipped"
        case "list_workflows":
            if let workflows = resultObject["workflows"] as? [[String: Any]] {
                return "\(workflows.count) workflows"
            }
        default:
            break
        }
        return nil
    }

    private var hasExpandablePayload: Bool {
        guard let raw = item.toolResultJSON?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return false
        }
        if let object = ToolRawJSON.object(from: item.toolResultJSON),
           ToolRawJSON.bool(object, key: "summary_only") == true
        {
            return false
        }
        return true
    }

    var body: some View {
        ToolCardContainer(
            iconName: "tray.full",
            iconColor: ToolCardAccentResolver.color(for: "agent_manage"),
            title: title,
            detailText: nil,
            subtitle: subtitle,
            status: status,
            timestamp: item.timestamp,
            isExpandable: hasExpandablePayload,
            isExpanded: $isExpanded
        ) {
            ToolMarkdownExpandedContent(item: item)
        }
    }
}
