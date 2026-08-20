import Foundation
import RepoPromptDomainRuntime

typealias AgentRunMCPSnapshot = DomainAgentRunSnapshot

extension DomainAgentRunSnapshot.WorktreeBinding {
    init(binding: AgentSessionWorktreeBinding, unavailable: Bool? = nil) {
        self.init(
            id: binding.id,
            repositoryID: binding.repositoryID,
            repoKey: binding.repoKey,
            logicalRootPath: binding.logicalRootPath,
            logicalRootName: binding.logicalRootName,
            worktreeID: binding.worktreeID,
            worktreeRootPath: binding.worktreeRootPath,
            worktreeName: binding.worktreeName,
            branch: binding.branch,
            head: binding.head,
            visualLabel: binding.visualLabel,
            visualColorHex: binding.visualColorHex,
            boundAt: binding.boundAt,
            source: binding.source,
            unavailable: unavailable ?? !FileManager.default.fileExists(atPath: binding.worktreeRootPath)
        )
    }
}

extension DomainAgentRunSnapshot.HookGate {
    init(audit: AgentCodexHookGateAudit) {
        let status: Status = switch audit.status {
        case .approvedAll: .approvedAll
        case .approvedSelected: .approvedSelected
        case .continuedWithoutHooks: .continuedWithoutHooks
        case .resolvedExternally: .resolvedExternally
        }
        self.init(
            status: status,
            approvedHookCount: audit.approvedCount,
            skippedHookCount: audit.skippedCount,
            resolvedAt: audit.resolvedAt
        )
    }
}

extension DomainAgentRunSnapshot {
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
        hookGate: HookGate? = nil,
        transcriptItemCount: Int,
        updatedAt: Date,
        parentSessionID: UUID?,
        failureReason: FailureReason?,
        worktreeBindings: [WorktreeBinding],
        appActiveWorktreeMerges: [AgentSessionWorktreeMergeSummary]
    ) {
        self.init(
            sessionID: sessionID,
            runID: runID,
            tabID: tabID,
            sessionName: sessionName,
            agentRaw: agentRaw,
            agentDisplayName: agentDisplayName,
            modelRaw: modelRaw,
            reasoningEffortRaw: reasoningEffortRaw,
            status: status,
            statusText: statusText,
            latestAssistantPreview: latestAssistantPreview,
            interaction: interaction,
            hookGate: hookGate,
            transcriptItemCount: transcriptItemCount,
            updatedAt: updatedAt,
            parentSessionID: parentSessionID,
            failureReason: failureReason,
            worktreeBindings: worktreeBindings,
            activeWorktreeMerges: appActiveWorktreeMerges.map {
                WorktreeMergeSummary(
                    id: $0.id,
                    status: $0.status.rawValue,
                    repositoryID: $0.repositoryID,
                    repoKey: $0.repoKey,
                    sourceWorktreeID: $0.sourceWorktreeID,
                    sourceLabel: $0.sourceLabel,
                    sourceBranch: $0.sourceBranch,
                    sourcePath: $0.sourcePath,
                    targetWorktreeID: $0.targetWorktreeID,
                    targetLabel: $0.targetLabel,
                    targetBranch: $0.targetBranch,
                    targetPath: $0.targetPath,
                    conflictFileCount: $0.conflictFileCount,
                    updatedAt: $0.updatedAt
                )
            }
        )
    }
}

extension DomainAgentRunSnapshot.Status {
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

extension DomainAgentRunSnapshot.FailureReason {
    var displayLabel: String {
        switch self {
        case .processCrash:
            "Process Crash"
        case .timeout:
            "Timeout"
        case .agentError:
            "Agent Error"
        case .cancelled:
            "Cancelled"
        }
    }
}

extension DomainAgentRunSnapshot.Interaction.Kind {
    var displayLabel: String {
        switch self {
        case .approval:
            "approval needed"
        case .hookApproval:
            "project hook approval"
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
