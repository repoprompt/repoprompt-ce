import Foundation
import MCP
import RepoPromptDomainRuntime

// Value types for managed pending-interaction inspection through `poll`/`wait` and explicit
// answers through `respond`. Observation first authorizes exact watch leases; a final whole-batch
// authority check proves the exact grant still has `.manage` before the bridge reads prompt bodies.
// Restricted grants receive no body. Respond instead obtains a `.manage` lease and revalidates it at its final authority
// hop, then compares the exact current interaction ID before synchronous submission.
//
// Nothing here answers anything automatically; every eligible response is one explicit,
// request-scoped action by the managed observer.

/// Why a pending interaction can be inspected but only answered by the target's own user.
enum AgentSessionLinkInteractionManualOnlyReason: String, Equatable {
    /// Codex project-hook trust is persistent project state, not a one-request decision.
    case hookApproval = "hook_approval"
    /// App-owned worktree merge reviews mutate another worktree and stay with the local user.
    case worktreeMergeReview = "worktree_merge_review"
    /// A field marked secret (for example a credential) is never supplied by another session.
    case secretInput = "secret_input"
    /// A wait for the session's next instruction is not a prompt `respond` answers. A managing
    /// observer delivers that instruction with `steer` instead.
    case instructionPrompt = "instruction_prompt"
    /// Session-wide or policy-amending approvals widen authority beyond this one request.
    case persistentDecision = "persistent_decision"
    /// An ACP provider offered no genuine one-time allow option for this request. Reported only
    /// when an observer tries to accept; decline and cancel stay available because both remain
    /// scoped to this one request.
    case noOneTimeAllowOption = "no_one_time_allow_option"
    /// The redacted prompt exceeds the hard single-target disclosure limit.
    case tooLarge = "too_large"
}

/// What the observer sees for one target's current pending interaction.
struct AgentSessionLinkPendingInteractionInspection: Equatable {
    /// Redacted interaction, restricted to the options an observer may choose. `nil` when the
    /// target has no pending interaction.
    let interaction: AgentRunMCPSnapshot.Interaction?
    /// Non-nil when the pending interaction exists but only the target's user may answer it.
    let manualOnlyReason: AgentSessionLinkInteractionManualOnlyReason?

    static let none = AgentSessionLinkPendingInteractionInspection(interaction: nil, manualOnlyReason: nil)
    static let promptMaxBytes = 64 * 1024
    /// A raw prompt that is far larger than any releasable object never enters regex redaction or
    /// JSON encoding on the main actor during routine poll/wait. Answering uses the same refusal.
    static let rawPromptWorkMaxBytes = 256 * 1024

    static func rawPromptExceedsWorkLimit(_ interaction: AgentRunMCPSnapshot.Interaction) -> Bool {
        var remaining = rawPromptWorkMaxBytes
        var itemCount = 0
        func consume(_ text: String?) -> Bool {
            guard let text else { return true }
            let bytes = text.utf8.count
            guard bytes <= remaining else { return false }
            remaining -= bytes
            return true
        }
        func consumeOption(_ option: AgentRunMCPSnapshot.Interaction.Option) -> Bool {
            itemCount += 1
            return itemCount <= 1024 && consume(option.label) && consume(option.description)
        }
        guard consume(interaction.title), consume(interaction.prompt), consume(interaction.context) else {
            return true
        }
        for option in interaction.options where !consumeOption(option) {
            return true
        }
        for field in interaction.fields {
            itemCount += 1
            guard itemCount <= 1024,
                  consume(field.id), consume(field.header), consume(field.prompt), consume(field.context)
            else { return true }
            for option in field.options where !consumeOption(option) {
                return true
            }
        }
        for detail in interaction.details {
            itemCount += 1
            guard itemCount <= 1024, consume(detail.label), consume(detail.value) else { return true }
        }
        return false
    }

    static func tooLarge(_ interaction: AgentRunMCPSnapshot.Interaction) -> Self {
        Self(
            interaction: AgentRunMCPSnapshot.Interaction(
                id: interaction.id,
                kind: interaction.kind,
                responseType: interaction.responseType,
                title: nil,
                prompt: nil,
                context: nil,
                allowsMultiple: nil,
                options: [],
                fields: [],
                details: []
            ),
            manualOnlyReason: .tooLarge
        )
    }

    static let instructionWaitNote =
        "This session is waiting for its next instruction, not asking a question. If your user's instruction calls for it, use `steer` to direct this managed session."

    /// The exact redacted object measured for the hard cap and, if it fits, emitted on the wire.
    func projectedObject() -> [String: Value]? {
        guard let interaction else { return nil }
        if manualOnlyReason == .tooLarge {
            return [
                "interaction_id": .string(interaction.id.uuidString),
                "kind": .string(interaction.kind.rawValue),
                "respondable": .bool(false),
                "manual_only_reason": .string(AgentSessionLinkInteractionManualOnlyReason.tooLarge.rawValue)
            ]
        }
        var object = interaction.asObject()
        object["interaction_id"] = .string(interaction.id.uuidString)
        object["respondable"] = .bool(manualOnlyReason == nil)
        object["manual_only_reason"] = manualOnlyReason.map { .string($0.rawValue) } ?? .null
        if manualOnlyReason != nil {
            object["options"] = .array([])
            if case let .array(fields)? = object["fields"] {
                object["fields"] = .array(fields.map { field in
                    guard case var .object(value) = field else { return field }
                    value["options"] = .array([])
                    return .object(value)
                })
            }
        }
        if manualOnlyReason == .instructionPrompt {
            object["note"] = .string(Self.instructionWaitNote)
        }
        return object
    }

    var exceedsPromptLimit: Bool {
        if manualOnlyReason == .tooLarge { return true }
        guard let object = projectedObject() else { return false }
        guard let bytes = try? JSONEncoder().encode(Value.object(object)).count else { return true }
        return bytes > Self.promptMaxBytes
    }
}

/// One explicit answer an observer asked RepoPrompt to submit on the target's behalf.
struct AgentSessionLinkInteractionResponseRequest: Equatable {
    let interactionID: UUID
    let payload: AgentModeViewModel.MCPInteractionResponsePayload
}

/// Host-level result of one respond attempt. Every case except `.submitted` applied nothing.
enum AgentSessionLinkInteractionResponseOutcome: Equatable {
    case submitted(kind: AgentRunMCPSnapshot.Interaction.Kind, decision: String?)
    case noPendingInteraction
    case interactionMismatch(currentInteractionID: UUID)
    case manualOnly(AgentSessionLinkInteractionManualOnlyReason)
    /// The answer did not fit the interaction; the message says why. Nothing was applied.
    case invalid(String)
    /// The target endpoint, grant, or management delegation stopped holding before submission.
    case unavailable
}

/// Bridge-level result: endpoint availability plus whatever the host reported. Management itself is
/// proven by the lease before the bridge is called.
enum AgentSessionLinkInteractionDisposition: Equatable {
    case denied
    case shuttingDown
    case responded(AgentSessionLinkInteractionResponseOutcome)
}
