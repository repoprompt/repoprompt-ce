import CryptoKit
import Foundation

/// Kind of the single top-priority interaction blocking an Agent Mode session.
///
/// Raw values are part of the notification `userInfo` contract (`interaction_kind`); never rename them.
enum AgentPendingInteractionKind: String, CaseIterable {
    case hookReview = "hook_review"
    case applyEditsReview = "apply_edits_review"
    case worktreeMergeReview = "worktree_merge_review"
    case approval
    case permissions
    case mcpElicitation = "mcp_elicitation"
    case userInput = "user_input"
    case askUser = "ask_user"
    case instruction
}

/// Value snapshot of what the user is being asked, derived from live session state.
///
/// The same builder is used when a notification is posted and again when a notification action is
/// handled, so the `fingerprint` binds an action to the exact content the notification displayed.
struct AgentPendingInteractionDescriptor: Equatable {
    static let defaultInstructionPrompt = "What would you like me to do next?"

    let id: UUID
    let kind: AgentPendingInteractionKind
    let title: String
    /// Primary content: the command, question, prompt, or path. Never truncated here.
    let detail: String?
    let approvalKind: AgentApprovalKind?
    /// Exact command an approval would authorize (approvals only).
    let command: String?
    /// Provider tool name when the approval names one (Claude `can_use_tool`), e.g. `Bash`.
    let toolName: String?
    let questionID: String?
    let questionCount: Int
    let optionLabels: [String]
    let allowsMultiple: Bool
    let allowsCustom: Bool
    let isSecret: Bool
    let fingerprint: String

    init(
        id: UUID,
        kind: AgentPendingInteractionKind,
        title: String,
        detail: String?,
        approvalKind: AgentApprovalKind? = nil,
        command: String? = nil,
        toolName: String? = nil,
        questionID: String? = nil,
        questionCount: Int = 0,
        optionLabels: [String] = [],
        allowsMultiple: Bool = false,
        allowsCustom: Bool = false,
        isSecret: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.approvalKind = approvalKind
        self.command = command
        self.toolName = toolName
        self.questionID = questionID
        self.questionCount = questionCount
        self.optionLabels = optionLabels
        self.allowsMultiple = allowsMultiple
        self.allowsCustom = allowsCustom
        self.isSecret = isSecret
        fingerprint = Self.fingerprint(
            id: id,
            kind: kind,
            title: title,
            detail: detail,
            approvalKind: approvalKind,
            command: command,
            toolName: toolName,
            questionID: questionID,
            questionCount: questionCount,
            optionLabels: optionLabels,
            allowsMultiple: allowsMultiple,
            allowsCustom: allowsCustom,
            isSecret: isSecret
        )
    }

    /// First 16 bytes of SHA-256 over a canonical, unit-separator-joined tuple, hex encoded.
    static func fingerprint(
        id: UUID,
        kind: AgentPendingInteractionKind,
        title: String,
        detail: String?,
        approvalKind: AgentApprovalKind?,
        command: String?,
        toolName: String?,
        questionID: String?,
        questionCount: Int,
        optionLabels: [String],
        allowsMultiple: Bool,
        allowsCustom: Bool,
        isSecret: Bool
    ) -> String {
        let separator = "\u{1F}"
        let fields: [String] = [
            "v1",
            kind.rawValue,
            id.uuidString,
            title,
            detail ?? "\u{0}",
            approvalKind?.rawValue ?? "",
            command ?? "\u{0}",
            toolName ?? "",
            questionID ?? "",
            String(questionCount),
            optionLabels.joined(separator: "\u{1E}"),
            allowsMultiple ? "1" : "0",
            allowsCustom ? "1" : "0",
            isSecret ? "1" : "0"
        ]
        let digest = SHA256.hash(data: Data(fields.joined(separator: separator).utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

extension AgentPendingInteractionDescriptor {
    /// Builds the descriptor for the interaction whose card is currently shown for `session`.
    ///
    /// Priority mirrors the bottom-of-transcript card chain in `AgentModeView`, with Codex permission
    /// requests slotted after command approvals (they share the approval family).
    @MainActor
    static func make(from session: AgentTabSession) -> AgentPendingInteractionDescriptor? {
        if let request = session.pendingCodexHookReview {
            return AgentPendingInteractionDescriptor(
                id: request.id,
                kind: .hookReview,
                title: "Project Hook Approval",
                detail: "Codex is waiting for project-hook trust in \(request.executionCWD)."
            )
        }
        if let review = session.pendingApplyEditsReview {
            return AgentPendingInteractionDescriptor(
                id: review.id,
                kind: .applyEditsReview,
                title: "Review Edit",
                detail: review.path
            )
        }
        if let review = session.pendingWorktreeMergeReview {
            return AgentPendingInteractionDescriptor(
                id: review.id,
                kind: .worktreeMergeReview,
                title: "Worktree Merge Review",
                detail: "Merge \(review.sourceLabel) into \(review.targetLabel)."
            )
        }
        if let approval = session.pendingApproval {
            // The command is kept byte-exact (no trimming): it is what an Approve would authorize.
            let command = approval.command.flatMap { $0.isEmpty ? nil : $0 }
            let toolName = approval.details.first(where: { $0.label == "Tool" })?.value
            return AgentPendingInteractionDescriptor(
                id: approval.id,
                kind: .approval,
                title: approval.title,
                detail: command ?? nonEmpty(approval.reason) ?? nonEmpty(approval.grantRoot),
                approvalKind: approval.kind,
                command: command,
                toolName: toolName
            )
        }
        if let request = session.pendingPermissionsRequest {
            return AgentPendingInteractionDescriptor(
                id: request.id,
                kind: .permissions,
                title: request.title,
                detail: nonEmpty(request.reason) ?? "Requested additional permissions in \(request.cwd)."
            )
        }
        if let request = session.pendingMCPElicitationRequest {
            return AgentPendingInteractionDescriptor(
                id: request.id,
                kind: .mcpElicitation,
                title: request.title,
                detail: nonEmpty(request.prompt) ?? nonEmpty(request.message)
            )
        }
        if let request = session.pendingUserInputRequest {
            let single = request.questions.count == 1 ? request.questions.first : nil
            return AgentPendingInteractionDescriptor(
                id: request.id,
                kind: .userInput,
                title: nonEmpty(single?.header) ?? "Input Requested",
                detail: single.map(\.question) ?? "Provide the requested input (\(request.questions.count) questions).",
                questionID: single?.id,
                questionCount: request.questions.count,
                optionLabels: single?.options.map(\.label) ?? [],
                allowsMultiple: false,
                allowsCustom: single.map { $0.options.isEmpty || $0.isOtherOptionEnabled } ?? false,
                isSecret: request.questions.contains(where: \.isSecret)
            )
        }
        if let pending = session.pendingAskUser {
            let interaction = pending.interaction
            let single = interaction.questions.count == 1 ? interaction.questions.first : nil
            return AgentPendingInteractionDescriptor(
                id: interaction.id,
                kind: .askUser,
                title: nonEmpty(interaction.title) ?? nonEmpty(single?.header) ?? "Question",
                detail: single.map(\.question) ?? "Answer \(interaction.questions.count) questions.",
                questionID: single?.id,
                questionCount: interaction.questions.count,
                optionLabels: single?.optionLabels ?? [],
                allowsMultiple: single?.allowsMultiple ?? true,
                allowsCustom: single?.allowsCustom ?? false
            )
        }
        if session.runState == .waitingForUser,
           session.instructionContinuation != nil,
           let waitID = session.instructionWaitID
        {
            return AgentPendingInteractionDescriptor(
                id: waitID,
                kind: .instruction,
                title: "Waiting for Your Instruction",
                detail: nonEmpty(session.waitingPrompt) ?? defaultInstructionPrompt,
                allowsCustom: true
            )
        }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
