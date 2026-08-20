import Foundation
import MCP

public enum DomainAgentRunEpochTransitionKind: String, Codable, Equatable, Hashable, Sendable {
    case initial
    case relatedFollowUp
    case steering
    case unrelated
}

public struct DomainAgentRunTurnEpoch: Codable, Equatable, Hashable, Sendable {
    public let runtimeID: UUID
    public let runtimeGeneration: UInt64
    public let sessionID: UUID
    public let activationID: UUID
    public let registrationGeneration: UInt64
    public let id: UUID
    public let ordinal: UInt64
    public let continuityGeneration: UInt64
    public let transitionKind: DomainAgentRunEpochTransitionKind

    public init(
        runtimeID: UUID = DomainRuntimeCompatibilityIdentity.runtimeID,
        runtimeGeneration: UInt64 = 0,
        sessionID: UUID,
        activationID: UUID,
        registrationGeneration: UInt64,
        id: UUID,
        ordinal: UInt64,
        continuityGeneration: UInt64,
        transitionKind: DomainAgentRunEpochTransitionKind
    ) {
        self.runtimeID = runtimeID
        self.runtimeGeneration = runtimeGeneration
        self.sessionID = sessionID
        self.activationID = activationID
        self.registrationGeneration = registrationGeneration
        self.id = id
        self.ordinal = ordinal
        self.continuityGeneration = continuityGeneration
        self.transitionKind = transitionKind
    }
}

public struct DomainAgentRunTerminalPublicationEnvelope: Equatable, Sendable {
    public let epoch: DomainAgentRunTurnEpoch
    public let snapshot: DomainAgentRunSnapshot

    public init(epoch: DomainAgentRunTurnEpoch, snapshot: DomainAgentRunSnapshot) {
        self.epoch = epoch
        self.snapshot = snapshot
    }
}

public enum DomainAgentRunTerminalPublicationResult: Equatable, Sendable {
    case accepted(successorEpoch: DomainAgentRunTurnEpoch?)
    case stale
    case rejected(reason: String)

    public var successorEpoch: DomainAgentRunTurnEpoch? {
        guard case let .accepted(successorEpoch) = self else { return nil }
        return successorEpoch
    }

    public var isResolved: Bool {
        switch self {
        case .accepted, .stale:
            true
        case .rejected:
            false
        }
    }
}

public struct DomainAgentRunSnapshot: Equatable, Sendable {
    public static let startupPendingStatusText = "Queued to start"

    public enum Status: String, Codable, Equatable, Sendable {
        case running
        case waitingForInput = "waiting_for_input"
        case completed
        case failed
        case cancelled
        case expired

        public var isTerminal: Bool {
            switch self {
            case .completed, .failed, .cancelled, .expired:
                true
            case .running, .waitingForInput:
                false
            }
        }
    }

    public struct WorktreeBinding: Codable, Equatable, Sendable {
        public let id: String
        public let repositoryID: String
        public let repoKey: String
        public let logicalRootPath: String
        public let logicalRootName: String?
        public let worktreeID: String
        public let worktreeRootPath: String
        public let worktreeName: String?
        public let branch: String?
        public let head: String?
        public let visualLabel: String?
        public let visualColorHex: String?
        public let boundAt: Date
        public let source: String
        public let unavailable: Bool

        public init(
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

        public func asObject() -> [String: Value] {
            [
                "id": .string(id),
                "repository_id": .string(repositoryID),
                "repo_key": .string(repoKey),
                "logical_root_path": .string(logicalRootPath),
                "logical_root_name": Self.stringOrNull(logicalRootName),
                "worktree_id": .string(worktreeID),
                "worktree_root_path": .string(worktreeRootPath),
                "worktree_name": Self.stringOrNull(worktreeName),
                "branch": Self.stringOrNull(branch),
                "head": Self.stringOrNull(head),
                "visual_label": Self.stringOrNull(visualLabel),
                "visual_color_hex": Self.stringOrNull(visualColorHex),
                "bound_at": .string(DomainAgentRunSnapshot.timestamp(boundAt)),
                "source": .string(source),
                "unavailable": .bool(unavailable)
            ]
        }

        private static func stringOrNull(_ value: String?) -> Value {
            value.map(Value.string) ?? .null
        }
    }

    public struct WorktreeMergeSummary: Codable, Equatable, Sendable {
        public let id: String
        public let status: String
        public let repositoryID: String
        public let repoKey: String
        public let sourceWorktreeID: String
        public let sourceLabel: String
        public let sourceBranch: String?
        public let sourcePath: String
        public let targetWorktreeID: String
        public let targetLabel: String
        public let targetBranch: String?
        public let targetPath: String
        public let conflictFileCount: Int
        public let updatedAt: Date

        public init(
            id: String,
            status: String,
            repositoryID: String,
            repoKey: String,
            sourceWorktreeID: String,
            sourceLabel: String,
            sourceBranch: String?,
            sourcePath: String,
            targetWorktreeID: String,
            targetLabel: String,
            targetBranch: String?,
            targetPath: String,
            conflictFileCount: Int,
            updatedAt: Date
        ) {
            self.id = id
            self.status = status
            self.repositoryID = repositoryID
            self.repoKey = repoKey
            self.sourceWorktreeID = sourceWorktreeID
            self.sourceLabel = sourceLabel
            self.sourceBranch = sourceBranch
            self.sourcePath = sourcePath
            self.targetWorktreeID = targetWorktreeID
            self.targetLabel = targetLabel
            self.targetBranch = targetBranch
            self.targetPath = targetPath
            self.conflictFileCount = conflictFileCount
            self.updatedAt = updatedAt
        }
    }

    public struct Interaction: Equatable, Sendable {
        public enum Kind: String, Equatable, Sendable {
            case instruction
            case question
            case userInput = "user_input"
            case approval
            case mcpElicitation = "mcp_elicitation"
        }

        public enum ResponseType: String, Equatable, Sendable {
            case text
            case choice
            case structured
            case decision
            case elicitation
        }

        public struct Option: Equatable, Sendable {
            public let label: String
            public let description: String?

            public init(label: String, description: String? = nil) {
                self.label = label
                self.description = description
            }

            public func asObject() -> [String: Value] {
                [
                    "label": .string(label),
                    "description": description.map(Value.string) ?? .null
                ]
            }
        }

        public struct Field: Equatable, Sendable {
            public let id: String
            public let header: String?
            public let prompt: String
            public let context: String?
            public let isSecret: Bool
            public let allowsOther: Bool
            public let allowsMultiple: Bool?
            public let allowsCustom: Bool?
            public let emitAllowsOther: Bool
            public let options: [Option]

            public init(
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

            public func asObject() -> [String: Value] {
                var object: [String: Value] = [
                    "id": .string(id),
                    "header": header.map(Value.string) ?? .null,
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

        public struct Detail: Equatable, Sendable {
            public let label: String
            public let value: String
            public let isCode: Bool

            public init(label: String, value: String, isCode: Bool) {
                self.label = label
                self.value = value
                self.isCode = isCode
            }

            public func asObject() -> [String: Value] {
                [
                    "label": .string(label),
                    "value": .string(value),
                    "is_code": .bool(isCode)
                ]
            }
        }

        public let id: UUID
        public let kind: Kind
        public let responseType: ResponseType
        public let title: String?
        public let prompt: String?
        public let context: String?
        public let allowsMultiple: Bool?
        public let options: [Option]
        public let fields: [Field]
        public let details: [Detail]

        public init(
            id: UUID,
            kind: Kind,
            responseType: ResponseType,
            title: String?,
            prompt: String?,
            context: String?,
            allowsMultiple: Bool?,
            options: [Option],
            fields: [Field],
            details: [Detail]
        ) {
            self.id = id
            self.kind = kind
            self.responseType = responseType
            self.title = title
            self.prompt = prompt
            self.context = context
            self.allowsMultiple = allowsMultiple
            self.options = options
            self.fields = fields
            self.details = details
        }

        public func asObject() -> [String: Value] {
            var object: [String: Value] = [
                "id": .string(id.uuidString),
                "kind": .string(kind.rawValue),
                "response_type": .string(responseType.rawValue),
                "title": title.map(Value.string) ?? .null,
                "prompt": prompt.map(Value.string) ?? .null
            ]
            if let context {
                object["context"] = .string(context)
            }
            if let allowsMultiple {
                object["allows_multiple"] = .bool(allowsMultiple)
            }
            if !options.isEmpty {
                object["options"] = .array(options.map { .object($0.asObject()) })
            }
            if !fields.isEmpty {
                object["fields"] = .array(fields.map { .object($0.asObject()) })
            }
            if !details.isEmpty {
                object["details"] = .array(details.map { .object($0.asObject()) })
            }
            return object
        }
    }

    public enum FailureReason: String, Equatable, Sendable {
        case processCrash = "process_crash"
        case timeout
        case agentError = "agent_error"
        case cancelled

        /// Fallback heuristic for restored/legacy snapshots whose terminal
        /// settlement did not stamp a canonical failure reason. Live terminal
        /// classification is resolved exactly once by the terminal settlement
        /// authority; this text inference must not become the primary path.
        public static func classify(status: Status, statusText: String?) -> FailureReason? {
            if status == .cancelled { return .cancelled }
            guard status == .failed else { return nil }
            guard let text = statusText?.lowercased(), !text.isEmpty else { return .agentError }
            if ["cancelled", "canceled", "interrupted", "aborted"].contains(where: text.contains) {
                return .cancelled
            }
            if ["timed out", "timeout", "deadline exceeded", "took too long"].contains(where: text.contains) {
                return .timeout
            }
            if [
                "process not running", "transport closed", "connection closed", "broken pipe",
                "crashed", "crash", "exited unexpectedly", "terminated unexpectedly",
                "protocol error", "decode error", "spawn failed"
            ].contains(where: text.contains) {
                return .processCrash
            }
            return .agentError
        }
    }

    public let sessionID: UUID
    public let runID: UUID?
    public let tabID: UUID?
    public let sessionName: String?
    public let agentRaw: String?
    public let agentDisplayName: String?
    public let modelRaw: String?
    public let reasoningEffortRaw: String?
    public let status: Status
    public let statusText: String?
    public let latestAssistantPreview: String?
    public let interaction: Interaction?
    public let transcriptItemCount: Int
    public let updatedAt: Date
    public let parentSessionID: UUID?
    public let failureReason: FailureReason?
    public let worktreeBindings: [WorktreeBinding]
    public let activeWorktreeMerges: [WorktreeMergeSummary]

    public init(
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
        activeWorktreeMerges: [WorktreeMergeSummary]
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

    public var isActionableForMCPWait: Bool {
        interaction != nil || status == .waitingForInput || status.isTerminal
    }

    public var isStartupPendingForMCPWait: Bool {
        status == .running && runID == nil && statusText == Self.startupPendingStatusText
    }

    public func asObject() -> [String: Value] {
        var object: [String: Value] = [
            "session_id": .string(sessionID.uuidString),
            "status": .string(status.rawValue),
            "transcript_item_count": .int(transcriptItemCount),
            "updated_at": .string(Self.timestamp(updatedAt))
        ]
        if let runID {
            object["run_id"] = .string(runID.uuidString)
        }
        if let statusText, !statusText.isEmpty {
            object["status_text"] = .string(statusText)
        }
        if let latestAssistantPreview, !latestAssistantPreview.isEmpty {
            object["assistant_text"] = .string(latestAssistantPreview)
        }
        if let interaction {
            object["interaction"] = .object(interaction.asObject())
            object["interaction_id"] = .string(interaction.id.uuidString)
        }
        if let failureReason {
            object["failure_reason"] = .string(failureReason.rawValue)
        }

        var session: [String: Value] = [
            "id": .string(sessionID.uuidString),
            "name": sessionName.map(Value.string) ?? .null
        ]
        if let tabID {
            session["context_id"] = .string(tabID.uuidString)
        }
        if let parentSessionID {
            session["parent_session_id"] = .string(parentSessionID.uuidString)
        }
        object["session"] = .object(session)

        if agentRaw != nil || modelRaw != nil {
            object["agent"] = .object([
                "id": agentRaw.map(Value.string) ?? .null,
                "name": agentDisplayName.map(Value.string) ?? .null,
                "model": modelRaw.map(Value.string) ?? .null,
                "reasoning_effort": reasoningEffortRaw.map(Value.string) ?? .null
            ])
        }
        if !worktreeBindings.isEmpty {
            let values = worktreeBindings.map { Value.object($0.asObject()) }
            object["worktree_bindings"] = .array(values)
            object["worktree"] = values[0]
        }
        if !activeWorktreeMerges.isEmpty {
            object["active_worktree_merges"] = .array(activeWorktreeMerges.map { .object(Self.mergeSummaryObject($0)) })
        }
        return object
    }

    public func toValue() -> Value {
        .object(asObject())
    }

    public static func expired(sessionID: UUID) -> DomainAgentRunSnapshot {
        expired(
            sessionID: sessionID,
            statusText: "This session control handle is no longer available. Start a new run or use a more recent session ID."
        )
    }

    public static func expired(sessionID: UUID, statusText: String) -> DomainAgentRunSnapshot {
        DomainAgentRunSnapshot(
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

    private static func mergeSummaryObject(_ summary: WorktreeMergeSummary) -> [String: Value] {
        [
            "id": .string(summary.id),
            "status": .string(summary.status),
            "repository_id": .string(summary.repositoryID),
            "repo_key": .string(summary.repoKey),
            "source_worktree_id": .string(summary.sourceWorktreeID),
            "source_label": .string(summary.sourceLabel),
            "source_branch": summary.sourceBranch.map(Value.string) ?? .null,
            "source_path": .string(summary.sourcePath),
            "target_worktree_id": .string(summary.targetWorktreeID),
            "target_label": .string(summary.targetLabel),
            "target_branch": summary.targetBranch.map(Value.string) ?? .null,
            "target_path": .string(summary.targetPath),
            "conflict_file_count": .int(summary.conflictFileCount),
            "updated_at": .string(timestamp(summary.updatedAt))
        ]
    }

    fileprivate static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

public enum DomainRuntimeCompatibilityIdentity {
    public static let runtimeID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}
