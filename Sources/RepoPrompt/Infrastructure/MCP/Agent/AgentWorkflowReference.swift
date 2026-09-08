import Foundation
import MCP

/// The mutually exclusive `workflow_id` / `workflow_name` arguments shared by every MCP tool that
/// can attach a one-shot workflow to a turn.
///
/// Parsing and resolution are deliberately **two** steps rather than the single one `agent_run`
/// originally used. `agent_session_link.send` has to build its canonical request identity before it
/// authorizes the link — an unauthorized caller must not be able to probe which workflows exist —
/// and must not resolve anything at all when the send ledger already holds the outcome for that
/// idempotency key. Splitting the halves is what lets a duplicate replay survive a workflow that was
/// since renamed or deleted, while keeping the accepted reference forms, the case-insensitive name
/// match, and the caller-facing error strings identical across both tools.
enum AgentWorkflowReference: Equatable {
    /// A `workflow_id` argument.
    case id(String)
    /// A `workflow_name` argument.
    case name(String)

    /// The reference exactly as the caller wrote it, for error text and resolution.
    var reference: String {
        switch self {
        case let .id(value), let .name(value): value
        }
    }

    /// Stable identity of the *request*, never of the resolved workflow.
    ///
    /// A name is case-folded because resolution matches display names case-insensitively, so two
    /// spellings are genuinely one request. Deliberately derived from the caller's argument rather
    /// than from the resolved definition: workflow contents are mutable, and an idempotent retry
    /// must not become a conflict because the user edited the template in between.
    ///
    /// The two cases stay distinct even though the store resolves both through the same lookup
    /// (exact ID first, then case-insensitive display name). Switching the *field* between retries
    /// is treated as a different request and refused as a conflict, which delivers nothing and tells
    /// the caller — the safe direction for an argument change RepoPrompt cannot prove was a typo.
    var canonicalSelector: String {
        switch self {
        case let .id(value): "id:\(value)"
        case let .name(value): "name:\(value.lowercased())"
        }
    }

    /// Canonical selector for a call that named no workflow.
    static let noneSelector = "none"

    /// Parses the pair, or returns `nil` when the caller named no workflow.
    static func parse(args: [String: Value]) throws -> AgentWorkflowReference? {
        let workflowID = AgentMCPToolHelpers.normalizedString(args["workflow_id"])
        let workflowName = AgentMCPToolHelpers.normalizedString(args["workflow_name"])
        if workflowID != nil, workflowName != nil {
            throw MCPError.invalidParams("Specify either workflow_id or workflow_name, not both.")
        }
        if let workflowID { return .id(workflowID) }
        if let workflowName { return .name(workflowName) }
        return nil
    }

    /// Canonical selector for an optional reference, so callers do not have to branch on `nil`.
    static func canonicalSelector(for reference: AgentWorkflowReference?) -> String {
        reference?.canonicalSelector ?? noneSelector
    }

    /// The live definition, or `nil` when nothing currently answers to this reference.
    ///
    /// Non-throwing so a caller that must unwind its own state first — a reserved send, say — can do
    /// that before deciding how to report the failure. `notFoundMessage` keeps that report identical
    /// to the one `agent_run` produces.
    @MainActor
    func resolved() -> AgentWorkflowDefinition? {
        AgentWorkflowStore.shared.resolveWorkflowReference(reference)
    }

    /// Single-sourced wording for a reference nothing answers to.
    var notFoundMessage: String {
        Self.notFoundMessage(reference: reference)
    }

    /// Same wording for a caller that only kept the raw reference — the send path reports the
    /// failure after the parsed value has already done its job and gone out of scope.
    static func notFoundMessage(reference: String) -> String {
        "Workflow '\(reference)' was not found."
    }
}
