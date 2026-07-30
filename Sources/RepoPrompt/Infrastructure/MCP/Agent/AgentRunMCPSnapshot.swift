import Foundation
import MCP

struct AgentRunMCPSnapshot: Equatable {
    static let startupPendingStatusText = "Queued to start"

    enum Status: String, Equatable {
        case running
        case waitingForInput = "waiting_for_input"
        case completed
        case failed
        case cancelled
        case expired

        var isTerminal: Bool {
            switch self {
            case .completed, .failed, .cancelled, .expired:
                true
            case .running, .waitingForInput:
                false
            }
        }
    }

    struct WorktreeBinding: Equatable {
        let id: String
        let repositoryID: String
        let repoKey: String
        let logicalRootPath: String
        let logicalRootName: String?
        let worktreeID: String
        let worktreeRootPath: String
        let worktreeName: String?
        let branch: String?
        let head: String?
        let visualLabel: String?
        let visualColorHex: String?
        let boundAt: Date
        let source: String
        let unavailable: Bool

        init(binding: AgentSessionWorktreeBinding, unavailable: Bool? = nil) {
            id = binding.id
            repositoryID = binding.repositoryID
            repoKey = binding.repoKey
            logicalRootPath = binding.logicalRootPath
            logicalRootName = binding.logicalRootName
            worktreeID = binding.worktreeID
            worktreeRootPath = binding.worktreeRootPath
            worktreeName = binding.worktreeName
            branch = binding.branch
            head = binding.head
            visualLabel = binding.visualLabel
            visualColorHex = binding.visualColorHex
            boundAt = binding.boundAt
            source = binding.source
            self.unavailable = unavailable ?? !FileManager.default.fileExists(atPath: binding.worktreeRootPath)
        }

        init(
            id: String,
            repositoryID: String,
            repoKey: String,
            logicalRootPath: String,
            logicalRootName: String?,
            worktreeID: String,
            worktreeRootPath: String,
            worktreeName: String?,
            branch: String?,
            head: String?,
            visualLabel: String?,
            visualColorHex: String?,
            boundAt: Date,
            source: String,
            unavailable: Bool
        ) {
            self.id = id
            self.repositoryID = repositoryID
            self.repoKey = repoKey
            self.logicalRootPath = logicalRootPath
            self.logicalRootName = logicalRootName
            self.worktreeID = worktreeID
            self.worktreeRootPath = worktreeRootPath
            self.worktreeName = worktreeName
            self.branch = branch
            self.head = head
            self.visualLabel = visualLabel
            self.visualColorHex = visualColorHex
            self.boundAt = boundAt
            self.source = source
            self.unavailable = unavailable
        }

        func asObject() -> [String: Value] {
            [
                "id": .string(id),
                "repository_id": .string(repositoryID),
                "repo_key": .string(repoKey),
                "logical_root_path": .string(logicalRootPath),
                "logical_root_name": AgentMCPToolHelpers.stringOrNull(logicalRootName),
                "worktree_id": .string(worktreeID),
                "worktree_root_path": .string(worktreeRootPath),
                "worktree_name": AgentMCPToolHelpers.stringOrNull(worktreeName),
                "branch": AgentMCPToolHelpers.stringOrNull(branch),
                "head": AgentMCPToolHelpers.stringOrNull(head),
                "visual_label": AgentMCPToolHelpers.stringOrNull(visualLabel),
                "visual_color_hex": AgentMCPToolHelpers.stringOrNull(visualColorHex),
                "bound_at": .string(AgentMCPToolHelpers.timestampFormatter.string(from: boundAt)),
                "source": .string(source),
                "unavailable": .bool(unavailable)
            ]
        }
    }

    struct Interaction: Equatable {
        enum Kind: String, Equatable {
            case instruction
            case question
            case userInput = "user_input"
            case approval
            case mcpElicitation = "mcp_elicitation"
        }

        /// Indicates the expected shape of a valid response.
        enum ResponseType: String, Equatable {
            case text
            case choice
            case structured
            case decision
            case elicitation
        }

        struct Option: Equatable {
            let label: String
            let description: String?

            func asObject() -> [String: Value] {
                [
                    "label": .string(label),
                    "description": AgentMCPToolHelpers.stringOrNull(description)
                ]
            }
        }

        /// Generic input field, used for `user_input` interactions (replaces `Question`).
        struct Field: Equatable {
            let id: String
            let header: String?
            let prompt: String
            let context: String?
            let isSecret: Bool
            let allowsOther: Bool
            let allowsMultiple: Bool?
            let allowsCustom: Bool?
            let emitAllowsOther: Bool
            let options: [Option]

            init(
                id: String,
                header: String? = nil,
                prompt: String,
                context: String? = nil,
                isSecret: Bool,
                allowsOther: Bool,
                allowsMultiple: Bool? = nil,
                allowsCustom: Bool? = nil,
                emitAllowsOther: Bool = true,
                options: [Option]
            ) {
                self.id = id
                self.header = header
                self.prompt = prompt
                self.context = context
                self.isSecret = isSecret
                self.allowsOther = allowsOther
                self.allowsMultiple = allowsMultiple
                self.allowsCustom = allowsCustom
                self.emitAllowsOther = emitAllowsOther
                self.options = options
            }

            func asObject() -> [String: Value] {
                var object: [String: Value] = [
                    "id": .string(id),
                    "header": AgentMCPToolHelpers.stringOrNull(header),
                    "prompt": .string(prompt),
                    "is_secret": .bool(isSecret),
                    "options": .array(options.map { .object($0.asObject()) })
                ]
                if let context {
                    object["context"] = .string(context)
                }
                if emitAllowsOther {
                    object["allows_other"] = .bool(allowsOther)
                }
                if let allowsMultiple {
                    object["allows_multiple"] = .bool(allowsMultiple)
                }
                if let allowsCustom {
                    object["allows_custom"] = .bool(allowsCustom)
                }
                return object
            }
        }

        struct Detail: Equatable {
            let label: String
            let value: String
            let isCode: Bool

            func asObject() -> [String: Value] {
                [
                    "label": .string(label),
                    "value": .string(value),
                    "is_code": .bool(isCode)
                ]
            }
        }

        let id: UUID
        let kind: Kind
        let responseType: ResponseType
        let title: String?
        let prompt: String?
        let context: String?
        let allowsMultiple: Bool?
        let options: [Option]
        let fields: [Field]
        let details: [Detail]

        func asObject() -> [String: Value] {
            var obj: [String: Value] = [
                "id": .string(id.uuidString),
                "kind": .string(kind.rawValue),
                "response_type": .string(responseType.rawValue),
                "title": Self.stringOrNull(title),
                "prompt": Self.stringOrNull(prompt)
            ]
            if let context {
                obj["context"] = .string(context)
            }
            if let allowsMultiple {
                obj["allows_multiple"] = .bool(allowsMultiple)
            }
            if !options.isEmpty {
                obj["options"] = .array(options.map { .object($0.asObject()) })
            }
            if !fields.isEmpty {
                obj["fields"] = .array(fields.map { .object($0.asObject()) })
            }
            if !details.isEmpty {
                obj["details"] = .array(details.map { .object($0.asObject()) })
            }
            return obj
        }

        private static func stringOrNull(_ value: String?) -> Value {
            AgentMCPToolHelpers.stringOrNull(value)
        }
    }

    // MARK: - Failure reason classification

    enum FailureReason: String, Equatable {
        case processCrash = "process_crash"
        case timeout
        case agentError = "agent_error"
        case cancelled

        var displayLabel: String {
            switch self {
            case .processCrash: "Process Crash"
            case .timeout: "Timeout"
            case .agentError: "Agent Error"
            case .cancelled: "Cancelled"
            }
        }

        static func classify(status: Status, statusText: String?) -> FailureReason? {
            if status == .cancelled { return .cancelled }
            guard status == .failed else { return nil }
            guard let text = statusText?.lowercased(), !text.isEmpty else { return .agentError }

            let cancelPatterns = ["cancelled", "canceled", "interrupted", "aborted"]
            if cancelPatterns.contains(where: { text.contains($0) }) { return .cancelled }

            let timeoutPatterns = ["timed out", "timeout", "deadline exceeded", "took too long"]
            if timeoutPatterns.contains(where: { text.contains($0) }) { return .timeout }

            let crashPatterns = [
                "process not running", "transport closed", "connection closed",
                "broken pipe", "crashed", "crash", "exited unexpectedly",
                "terminated unexpectedly", "protocol error", "decode error", "spawn failed"
            ]
            if crashPatterns.contains(where: { text.contains($0) }) { return .processCrash }

            return .agentError
        }
    }

    // MARK: - Snapshot properties

    let sessionID: UUID
    let runID: UUID?
    let tabID: UUID?
    let sessionName: String?

    let agentRaw: String?
    let agentDisplayName: String?
    let modelRaw: String?
    let reasoningEffortRaw: String?
    let status: Status
    let statusText: String?
    /// Latest assistant text. Serialized as `preview` while the run is active and as
    /// `output` once the run reaches a terminal state.
    let latestAssistantPreview: String?
    let interaction: Interaction?
    let transcriptItemCount: Int
    let updatedAt: Date
    let parentSessionID: UUID?
    let failureReason: FailureReason?
    let worktreeBindings: [WorktreeBinding]
    let activeWorktreeMerges: [AgentSessionWorktreeMergeSummary]

    init(
        sessionID: UUID,
        runID: UUID? = nil,
        tabID: UUID?,
        sessionName: String?,
        agentRaw: String?,
        agentDisplayName: String?,
        modelRaw: String?,
        reasoningEffortRaw: String?,
        status: Status,
        statusText: String?,
        latestAssistantPreview: String?,
        interaction: Interaction?,
        transcriptItemCount: Int,
        updatedAt: Date,
        parentSessionID: UUID?,
        failureReason: FailureReason?,
        worktreeBindings: [WorktreeBinding],
        activeWorktreeMerges: [AgentSessionWorktreeMergeSummary]
    ) {
        self.sessionID = sessionID
        self.runID = runID
        self.tabID = tabID
        self.sessionName = sessionName
        self.agentRaw = agentRaw
        self.agentDisplayName = agentDisplayName
        self.modelRaw = modelRaw
        self.reasoningEffortRaw = reasoningEffortRaw
        self.status = status
        self.statusText = statusText
        self.latestAssistantPreview = latestAssistantPreview
        self.interaction = interaction
        self.transcriptItemCount = transcriptItemCount
        self.updatedAt = updatedAt
        self.parentSessionID = parentSessionID
        self.failureReason = failureReason
        self.worktreeBindings = worktreeBindings
        self.activeWorktreeMerges = activeWorktreeMerges
    }

    var isActionableForMCPWait: Bool {
        interaction != nil || status == .waitingForInput || status.isTerminal
    }

    var isStartupPendingForMCPWait: Bool {
        status == .running && runID == nil && statusText == Self.startupPendingStatusText
    }

    func asObject() -> [String: Value] {
        var obj: [String: Value] = [
            "session_id": .string(sessionID.uuidString),
            "status": .string(status.rawValue),
            "transcript_item_count": .int(transcriptItemCount),
            "updated_at": .string(Self.timestampFormatter.string(from: updatedAt))
        ]
        if let runID {
            obj["run_id"] = .string(runID.uuidString)
        }
        if let statusText, !statusText.isEmpty {
            obj["status_text"] = .string(statusText)
        }
        if let latestAssistantPreview, !latestAssistantPreview.isEmpty {
            obj["assistant_text"] = .string(latestAssistantPreview)
        }
        if let interaction {
            obj["interaction"] = .object(interaction.asObject())
            obj["interaction_id"] = .string(interaction.id.uuidString)
        }

        if let failureReason {
            obj["failure_reason"] = .string(failureReason.rawValue)
        }

        var sessionObj: [String: Value] = [
            "id": .string(sessionID.uuidString),
            "name": Self.stringOrNull(sessionName)
        ]
        if let tabID {
            sessionObj["context_id"] = .string(tabID.uuidString)
        }
        if let parentSessionID {
            sessionObj["parent_session_id"] = .string(parentSessionID.uuidString)
        }
        obj["session"] = .object(sessionObj)

        if agentRaw != nil || modelRaw != nil {
            obj["agent"] = .object([
                "id": Self.stringOrNull(agentRaw),
                "name": Self.stringOrNull(agentDisplayName),
                "model": Self.stringOrNull(modelRaw),
                "reasoning_effort": Self.stringOrNull(reasoningEffortRaw)
            ])
        }

        if !worktreeBindings.isEmpty {
            let values = worktreeBindings.map { Value.object($0.asObject()) }
            obj["worktree_bindings"] = .array(values)
            obj["worktree"] = values[0]
        }
        if !activeWorktreeMerges.isEmpty {
            obj["active_worktree_merges"] = .array(activeWorktreeMerges.map { .object(Self.mergeSummaryObject($0)) })
        }

        return obj
    }

    func toValue() -> Value {
        .object(asObject())
    }

    static func expired(sessionID: UUID) -> AgentRunMCPSnapshot {
        expired(
            sessionID: sessionID,
            statusText: "This session control handle is no longer available. Start a new run or use a more recent session ID."
        )
    }

    static func expired(sessionID: UUID, statusText: String) -> AgentRunMCPSnapshot {
        AgentRunMCPSnapshot(
            sessionID: sessionID,
            tabID: nil,
            sessionName: nil,
            agentRaw: nil,
            agentDisplayName: nil,
            modelRaw: nil,
            reasoningEffortRaw: nil,
            status: .expired,
            statusText: statusText,
            latestAssistantPreview: nil,
            interaction: nil,
            transcriptItemCount: 0,
            updatedAt: Date(),
            parentSessionID: nil,
            failureReason: nil,
            worktreeBindings: [],
            activeWorktreeMerges: []
        )
    }

    private static func stringOrNull(_ value: String?) -> Value {
        AgentMCPToolHelpers.stringOrNull(value)
    }

    private static func mergeSummaryObject(_ summary: AgentSessionWorktreeMergeSummary) -> [String: Value] {
        [
            "id": .string(summary.id),
            "status": .string(summary.status.rawValue),
            "repository_id": .string(summary.repositoryID),
            "repo_key": .string(summary.repoKey),
            "source_worktree_id": .string(summary.sourceWorktreeID),
            "source_label": .string(summary.sourceLabel),
            "source_branch": stringOrNull(summary.sourceBranch),
            "source_path": .string(summary.sourcePath),
            "target_worktree_id": .string(summary.targetWorktreeID),
            "target_label": .string(summary.targetLabel),
            "target_branch": stringOrNull(summary.targetBranch),
            "target_path": .string(summary.targetPath),
            "conflict_file_count": .int(summary.conflictFileCount),
            "updated_at": .string(timestampFormatter.string(from: summary.updatedAt))
        ]
    }

    private static let timestampFormatter = AgentMCPToolHelpers.timestampFormatter
}

// MARK: - Centralized Status & Delivery Display Text

// SEARCH-HELPER: Status labels, delivery wording, interaction kind display, agent control display text
//
// Related:
// - UI card presentation: Views/AgentMode/ToolCards/AgentControlToolCards.swift
// - MCP output formatter:  Services/MCP/ToolOutputFormatter.swift (formatAgentRun/formatAgentManage)

extension AgentRunMCPSnapshot.Status {
    /// Human-readable label for display in UI cards and formatted tool output.
    var displayLabel: String {
        switch self {
        case .running:
            "Still Running"
        case .waitingForInput:
            "Needs Input"
        case .completed:
            "Run Complete"
        case .failed:
            "Run Failed"
        case .cancelled:
            "Run Cancelled"
        case .expired:
            "Run Expired"
        }
    }

    /// Title-cased label suitable for MCP text output (e.g. "Waiting For Input").
    var prettifiedLabel: String {
        rawValue
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { word in
                guard let first = word.first else { return "" }
                return String(first).uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }
}

extension AgentRunMCPSnapshot.Interaction.Kind {
    /// Human-readable label for interaction kind.
    var displayLabel: String {
        switch self {
        case .approval:
            "approval needed"
        case .question:
            "question"
        case .instruction:
            "instruction"
        case .userInput:
            "input needed"
        case .mcpElicitation:
            "MCP elicitation"
        }
    }
}

extension AgentModeViewModel.MCPInstructionDispatch {
    /// Human-readable explanation of how an instruction was delivered.
    var deliveryExplanation: String? {
        switch self {
        case .startedRun:
            "Started a new run."
        case .deliveredIntoWaitingContinuation:
            "Delivered immediately into the pending prompt."
        case .queuedFollowUp:
            "Queued as the next turn once the active run reaches a safe handoff point."
        case .dispatchedCodexTurn:
            "Delivered to the active Codex run."
        case .queuedClaudeInterrupt:
            "Queued for Claude and requested an interrupt at the next decision point."
        case .queuedACPInterrupt:
            "Queued for ACP and will cancel the active prompt before sending steering."
        }
    }
}
