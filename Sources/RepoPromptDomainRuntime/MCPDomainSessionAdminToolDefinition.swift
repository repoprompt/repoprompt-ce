import Foundation
import MCP

/// Canonical schema for the agent-only `session_admin` tool.
///
/// Kept beside, not inside, the encoded catalog in `MCPDomainCanonicalToolDefinitions` so the
/// delegation surface can grow per lane without re-encoding every other tool. The tool is
/// policy-gated (`agentSessionAdmin`): it is canonical in every catalog but advertised only to an
/// exact Agent Mode run holding a live delegation scope (or, for `request_scope`, to an
/// orchestrator/overseer run), and never to administrative principals.
package enum MCPDomainSessionAdminToolDefinition {
    /// Milestone 1 operations. Lane A implements the scope lifecycle; the rest are reserved
    /// identities that currently return `not_implemented`.
    package static let operations: [String] = [
        "request_scope", "scope_status", "release_scope", "attenuate",
        "inventory", "get", "tree", "links",
        "rename", "set_pin", "reorder_pins", "set_group", "reorder_groups", "archive", "unarchive",
        "link", "unlink", "reparent", "adopt", "release", "retire",
        "fork", "set_model", "set_effort",
        "worktree_create", "worktree_bind", "worktree_unbind", "worktree_release", "worktree_inventory",
        "merge_preview", "merge_apply",
        "confirmation_status", "undo"
    ]

    /// Operations Lane A implements end to end.
    package static let implementedOperations: Set<String> = ["request_scope", "scope_status", "release_scope"]

    package static let capabilityValues: [String] = DomainDelegationScopeCapability.allCases.map(\.rawValue)

    package static let definition = MCPDomainToolDefinition(
        name: MCPWindowToolName.sessionAdmin,
        description: """
        Administer Agent sessions inside a delegation scope the user granted to this session. Agent sessions only.

        A scope is user-approved authority over a set of sessions: `tree` (this session's owned subtree), `workspace`, or `all_sessions`. Capabilities: observe, organize, control, restructure, spawn, worktree, destructive. `all_sessions` may hold only observe, organize, and restructure. Membership comes from RepoPrompt's own provenance, never from arguments; naming a session grants nothing.

        **Scope ops**
        - `request_scope`: ask the user for a scope. Returns `pending_user_approval` and a `request_id`; nothing is granted until the user approves the card.
        - `scope_status`: your live scopes, or one `scope_id`/`request_id` (pending, granted, denied, revoked, expired).
        - `release_scope`: give up one of your scopes; revokes its nested scopes too.

        Other ops are reserved and may return `not_implemented`.

        **Rules**: destructive ops and bulk ops over the scope threshold (default 25) return `pending_confirmation` for one user card. Recoverable denials: `scope_capability_missing`, `scope_guardrail_exceeded`, `scope_expired`, `confirmation_required`. Deleting sessions, removing worktrees, keys, permission modes, settings, and app control are human-only. Mutating calls take `idempotency_key`.
        """,
        inputSchema: .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "op": .object([
                    "type": .string("string"),
                    "enum": .array(operations.map(Value.string)),
                    "description": .string("Required operation.")
                ]),
                "kind": .object([
                    "type": .string("string"),
                    "enum": .array([.string("tree"), .string("workspace"), .string("all_sessions")]),
                    "description": .string("[request_scope] Scope kind; default tree rooted at this session.")
                ]),
                "workspace": .object([
                    "type": .string("string"),
                    "description": .string("[request_scope] Workspace UUID for kind=workspace; default this session's workspace.")
                ]),
                "capabilities": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("string"),
                        "enum": .array(capabilityValues.map(Value.string))
                    ]),
                    "description": .string("[request_scope] Requested capabilities; the user may narrow them.")
                ]),
                "guardrails": .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "properties": .object([
                        "max_live_sessions": .object(["type": .string("integer"), "minimum": .int(0)]),
                        "max_depth": .object(["type": .string("integer"), "minimum": .int(0)]),
                        "max_worktrees": .object(["type": .string("integer"), "minimum": .int(0)]),
                        "expires_in_seconds": .object(["type": .string("integer"), "minimum": .int(60)]),
                        "bulk_confirmation_threshold": .object(["type": .string("integer"), "minimum": .int(1)])
                    ]),
                    "description": .string("[request_scope] Proposed guardrails; the user may tighten them.")
                ]),
                "reason": .stringSchema("[request_scope] Why you need the scope; shown on the approval card. Max 500 UTF-8 bytes."),
                "scope_id": .stringSchema("[scope_status, release_scope, other ops] Scope UUID; optional when you hold exactly one live scope."),
                "request_id": .stringSchema("[scope_status] Request UUID returned by request_scope."),
                "session_id": .stringSchema("[target ops] One target session UUID."),
                "targets": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("[bulk ops] Target session UUIDs; exclusive with filter.")
                ]),
                "filter": .object([
                    "type": .string("object"),
                    "description": .string("[bulk ops] Inventory filter; exclusive with targets.")
                ]),
                "preview": .object([
                    "type": .string("boolean"),
                    "description": .string("[mutating ops] Dry run listing exact items and effects.")
                ]),
                "idempotency_key": .stringSchema("[request_scope, mutating ops] New per request; reuse only for the same retry. Max 200 UTF-8 bytes."),
                "confirmation_id": .stringSchema("[confirmation_status] Confirmation UUID from pending_confirmation.")
            ]),
            "required": .array([.string("op")])
        ]),
        annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
    )
}

private extension Value {
    static func stringSchema(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }
}
