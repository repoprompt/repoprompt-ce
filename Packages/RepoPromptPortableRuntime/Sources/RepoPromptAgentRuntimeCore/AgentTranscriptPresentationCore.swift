import Foundation
import RepoPromptRuntimeModel

public struct AgentSemanticPresentationActivity: Hashable, Sendable {
    public let id: String
    public let sequence: Int64
    public let revision: Int64
    public let kind: String
    public let content: String?
    public let summary: String?
    public let status: String?
    public let tool: AgentPresentationToolWire?

    public init(id: String, sequence: Int64, revision: Int64, kind: String, content: String? = nil, summary: String? = nil, status: String? = nil, tool: AgentPresentationToolWire? = nil) {
        self.id = id
        self.sequence = sequence
        self.revision = revision
        self.kind = kind
        self.content = content
        self.summary = summary
        self.status = status
        self.tool = tool
    }
}

public struct AgentSemanticPresentationTurn: Hashable, Sendable {
    public let turnID: String
    public let responseSpanID: String?
    public let requestAnchorID: UUID?
    public let requestText: String
    public let attachmentIDs: [UUID]
    public let taggedFiles: [ComposerTaggedFileReferenceWire]
    public let terminalState: String?
    public let activities: [AgentSemanticPresentationActivity]
    public let interactions: [AgentPresentationInteractionWire]

    public init(turnID: String, responseSpanID: String?, requestAnchorID: UUID?, requestText: String, attachmentIDs: [UUID] = [], taggedFiles: [ComposerTaggedFileReferenceWire] = [], terminalState: String? = nil, activities: [AgentSemanticPresentationActivity], interactions: [AgentPresentationInteractionWire] = []) {
        self.turnID = turnID
        self.responseSpanID = responseSpanID
        self.requestAnchorID = requestAnchorID
        self.requestText = requestText
        self.attachmentIDs = attachmentIDs
        self.taggedFiles = taggedFiles
        self.terminalState = terminalState
        self.activities = activities
        self.interactions = interactions
    }
}

public enum AgentTranscriptPresentationCore {
    public static func project(_ input: AgentSemanticPresentationTurn) -> AgentPresentationTurnWire {
        var blocks: [AgentPresentationBlockWire] = []
        let requestRow = AgentPresentationRowWire.userRequest(id: "\(input.turnID):request", text: input.requestText, attachmentIDs: input.attachmentIDs, taggedFiles: input.taggedFiles)
        blocks.append(.request(id: "\(input.turnID):request-block", row: requestRow))

        let sorted = input.activities
            .filter { !isLifecycleOnly($0) }
            .sorted { lhs, rhs in lhs.sequence == rhs.sequence ? (lhs.revision == rhs.revision ? lhs.id < rhs.id : lhs.revision < rhs.revision) : lhs.sequence < rhs.sequence }
        var cluster: [AgentPresentationRowWire] = []
        var clusterIndex = 0

        func flushCluster() {
            guard !cluster.isEmpty else { return }
            let tools = cluster.compactMap { row -> AgentPresentationToolWire? in if case let .tool(_, tool) = row { return tool }
                return nil
            }
            let summary = AgentActivityClusterSummaryWire(
                activityCount: cluster.count,
                toolCount: tools.count,
                toolGroups: Array(Set(tools.map(\.name))).sorted(),
                keyPaths: Array(Set(tools.flatMap(\.keyPaths))).sorted(),
                running: tools.contains { $0.status == .pending || $0.status == .running },
                warning: tools.contains { $0.status == .warning },
                failed: tools.contains { $0.status == .failed },
                narration: cluster.compactMap { row -> String? in
                    switch row { case let .thinking(_, text), let .progress(_, text), let .note(_, text): text
                    default: nil }
                }.last,
                title: tools.isEmpty ? "Activity" : (tools.count == 1 ? tools[0].name : "\(tools.count) tools"),
                iconSemantic: tools.contains(where: { $0.status == .failed }) ? "error" : "activity",
                defaultExpanded: tools.contains { $0.status == .running || $0.status == .failed }
            )
            blocks.append(.activityCluster(id: "\(input.turnID):activity:\(clusterIndex)", rows: cluster, summary: summary))
            clusterIndex += 1
            cluster.removeAll(keepingCapacity: true)
        }

        for activity in sorted {
            let text = activity.content ?? activity.summary ?? ""
            switch activity.kind {
            case "assistant":
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                flushCluster()
                blocks.append(.standaloneAssistant(id: activity.id, row: .assistant(id: activity.id, text: text)))
            case "reasoning":
                if !text.isEmpty { cluster.append(.thinking(id: activity.id, text: text)) }
            case "progress":
                if isMeaningfulProgress(text) { cluster.append(.progress(id: activity.id, text: text)) }
            case "tool":
                if let tool = activity.tool, isVisibleTool(tool) { cluster.append(.tool(id: activity.id, tool: tool)) }
            case "note":
                if !text.isEmpty { cluster.append(.note(id: activity.id, text: text)) }
            case "error":
                flushCluster()
                blocks.append(.conclusion(id: activity.id, row: .error(id: activity.id, text: text.isEmpty ? "The provider run failed." : text, code: activity.status)))
            case "conclusion":
                flushCluster()
                blocks.append(.conclusion(id: activity.id, row: .assistant(id: activity.id, text: text)))
            default:
                if !text.isEmpty { cluster.append(.note(id: activity.id, text: text)) }
            }
        }
        flushCluster()
        return AgentPresentationTurnWire(turnID: input.turnID, responseSpanID: input.responseSpanID, requestAnchorID: input.requestAnchorID, terminalState: input.terminalState, blocks: blocks, interactions: input.interactions)
    }

    public static func projectLegacy(_ entry: TranscriptEntry) -> AgentPresentationTurnWire? {
        guard !(entry.kind == .progress && normalized(entry.content) == "turn started") else { return nil }
        let id = "legacy:\(entry.entryID.uuidString.lowercased())"
        let row: AgentPresentationRowWire = switch entry.kind {
        case .human: .userRequest(id: id, text: entry.content, attachmentIDs: [], taggedFiles: [])
        case .assistant: .assistant(id: id, text: entry.content)
        case .reasoning: .thinking(id: id, text: entry.content)
        case .progress: .progress(id: id, text: entry.content)
        case .tool: .note(id: id, text: entry.content)
        case .system: .note(id: id, text: entry.content)
        }
        let block: AgentPresentationBlockWire = switch entry.kind {
        case .human: .request(id: "\(id):block", row: row)
        case .assistant: .standaloneAssistant(id: "\(id):block", row: row)
        case .tool: .standaloneTool(id: "\(id):block", row: row)
        case .system, .reasoning, .progress: .standaloneNote(id: "\(id):block", row: row)
        }
        return .init(turnID: id, blocks: [block], legacyStandalone: true)
    }

    /// Desktop `CodexAgentModeCoordinator.latestReasoningSummaryTitle`: the latest
    /// complete `**title**` line, used as the live run status when it reads as work.
    public static func latestReasoningStatusTitle(from markdown: String, maxTitleLength: Int = 80) -> String? {
        var latestTitle: String?
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("**"), trimmed.hasSuffix("**"), trimmed.count > 4 else { continue }
            let title = String(trimmed.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= maxTitleLength else { continue }
            latestTitle = title
        }
        return latestTitle
    }

    /// Desktop `shouldUseReasoningSummaryAsStatus`: keep noun-like headings out of the status line.
    public static func shouldUseReasoningSummaryAsStatus(_ title: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 60 else { return false }
        guard let firstWord = trimmed.split(whereSeparator: \.isWhitespace).first else { return false }
        let normalizedFirstWord = firstWord
            .trimmingCharacters(in: CharacterSet(charactersIn: ":.,!?()[]{}\"'“”‘’"))
            .lowercased()
        return normalizedFirstWord.hasSuffix("ing")
    }

    public static func reasoningStatusText(from markdown: String) -> String? {
        guard let title = latestReasoningStatusTitle(from: markdown),
              shouldUseReasoningSummaryAsStatus(title)
        else { return nil }
        return title
    }

    public static func normalizedToolName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let aliases = [
            "shell": "Bash",
            "bash": "Bash",
            "commandexecution": "Bash",
            "exec_command": "Command",
            "read_file": "Read file",
            "apply_patch": "Edit",
            "filechange": "Edit",
            "search": "Web search",
            "web_search": "Web search",
            "websearch": "Web search",
            "web_read": "Read web page",
            "mcptoolcall": "MCP tool"
        ]
        return aliases[trimmed.lowercased()] ?? (trimmed.isEmpty ? "Tool" : trimmed)
    }

    private static func isVisibleTool(_ tool: AgentPresentationToolWire) -> Bool {
        let normalizedName = tool.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
        // Older server builds persisted Codex item lifecycle frames as tools.
        // Suppress those malformed rows at the presentation boundary so existing
        // transcripts repair immediately without rewriting durable history.
        if ["reasoning", "agentmessage", "usermessage", "contextcompaction"].contains(normalizedName) {
            return false
        }
        let placeholder = ["", "tool", "other", "unknown"].contains(normalizedName)
        let meaningful = tool.summary?.isEmpty == false || tool.displayArguments?.isEmpty == false || tool.displayResult?.isEmpty == false || !tool.keyPaths.isEmpty
        return !placeholder || meaningful || [.failed, .warning].contains(tool.status)
    }

    private static func isLifecycleOnly(_ activity: AgentSemanticPresentationActivity) -> Bool {
        activity.kind == "progress" && normalized(activity.content ?? activity.summary ?? "") == "turn started"
    }

    private static func isMeaningfulProgress(_ value: String) -> Bool {
        let normalizedValue = normalized(value)
        return !normalizedValue.isEmpty && normalizedValue != "turn started" && normalizedValue != "working" && normalizedValue != "thinking"
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: ".", with: "")
    }
}
