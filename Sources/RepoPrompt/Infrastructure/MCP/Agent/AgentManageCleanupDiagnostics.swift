import Foundation
import MCP

/// Receipt projection only. Caller/target authority and deletion remain owned by the MCP service.
enum AgentManageCleanupDiagnostics {
    static func response(
        deletedSessions: [[String: Value]], skippedSessions: [[String: Value]],
        unprocessedSessions: [[String: Value]], requestedIDs: [UUID], wasCancelled: Bool
    ) -> Value {
        let skippedSessions = skippedSessions.map(Self.item)
        let unprocessedSessions = unprocessedSessions.map(Self.item)
        let deletedSessions = deletedSessions.map { item in
            var item = item
            if let providerStatus = item["provider_cleanup"]?.objectValue?["status"]?.stringValue,
               ["failed", "cancelled"].contains(providerStatus)
            {
                item["reason"] = .string("provider_cleanup_" + providerStatus)
                item["message"] = item["provider_cleanup"]?.objectValue?["message"]
            }
            return item["reason"] == nil ? item : Self.item(item)
        }
        // Only unchanged, potentially useful retries belong in this list. A durable deletion is
        // never retried to repair provider/local cleanup.
        let retrySessionIDs: [UUID] = (skippedSessions + unprocessedSessions).compactMap { item -> UUID? in
            guard item["retryable"] == .bool(true), let raw = item["session_id"]?.stringValue else { return nil }
            return UUID(uuidString: raw)
        }
        let hasUnresolved = skippedSessions.contains { $0["reason"] != .string("already_absent") }
            || !unprocessedSessions.isEmpty || deletedSessions.contains { $0["code"] != nil }
        let result = deletedSessions.isEmpty ? "not_applied" : (hasUnresolved ? "partial" : "applied")
        let status = wasCancelled ? "cancelled" : (hasUnresolved ? "partial" : "completed")
        return .object([
            "result": .string(result),
            "code": .string("cleanup_" + result), "subreason": .string(status),
            "detail": .string("Durable deletions are listed separately from skipped and unprocessed sessions."),
            "affected": .array(requestedIDs.map { .string($0.uuidString) }),
            "next_step": .string("Inspect per-session receipts below; do not repeat durable deletions to repair cleanup."),
            "retryable": .bool(!retrySessionIDs.isEmpty),
            "status": .string(status),
            "cancelled": .bool(wasCancelled),
            "processed_count": .int(deletedSessions.count + skippedSessions.count),
            "deleted_count": .int(deletedSessions.count),
            "skipped_count": .int(skippedSessions.count),
            "unprocessed_count": .int(unprocessedSessions.count),
            "deleted_sessions": .array(deletedSessions.map(Value.object)),
            "skipped_sessions": .array(skippedSessions.map(Value.object)),
            "unprocessed_sessions": .array(unprocessedSessions.map(Value.object)),
            "retry_session_ids": .array(retrySessionIDs.map { .string($0.uuidString) })
        ])
    }

    /// Whole-batch refusal before any lookup or mutation. A self-target refusal names only the
    /// caller's own item; the others were not applied because the batch is all-or-nothing.
    static func preflightRefused(reason: String, requestedIDs: [UUID], callerID: UUID?) -> Value {
        let items = requestedIDs.map { id in
            let itemReason = reason == "self_target" && callerID != nil && id != callerID
                ? "batch_preflight_not_applied" : reason
            return Value.object(item(["session_id": .string(id.uuidString), "reason": .string(itemReason)]))
        }
        var result = item(["reason": .string(reason)])
        result["result"] = .string("not_applied")
        result["affected"] = .array(requestedIDs.map { .string($0.uuidString) })
        result["deleted_count"] = .int(0)
        result["skipped_count"] = .int(items.count)
        result["skipped_sessions"] = .array(items)
        result["unprocessed_sessions"] = .array([])
        result["deleted_sessions"] = .array([])
        result["retry_session_ids"] = .array([])
        result["unprocessed_count"] = .int(0)
        result["processed_count"] = .int(items.count)
        result["status"] = .string("refused")
        result["cancelled"] = .bool(false)
        return .object(result)
    }

    /// The deletion's storage commit fence refused: the caller's authority ended while it waited.
    static func commitRefusedItem(sessionID: UUID, name: String) -> [String: Value] {
        [
            "session_id": .string(sessionID.uuidString),
            "name": .string(name),
            "reason": .string("authority_changed_before_commit"),
            "message": .string("The caller's authority (full access, routing, connection or workspace) changed before the deletion committed; nothing was deleted. Re-check with session_admin scope_status, then retry."),
            "durable": .bool(false)
        ]
    }

    static func item(_ item: [String: Value]) -> [String: Value] {
        var item = item
        let reason = item["reason"]?.stringValue ?? "cleanup_failed"
        let detail: String
        let next: String
        let retryable: Bool
        switch reason {
        case "human_only_operation":
            detail = "Session deletion is human-only when Overseer full access is OFF; scopes and links cannot authorize it."
            next = "Ask the user to delete the sessions in the app. A scope approval does not authorize deletion."
            retryable = false
        case "caller_or_workspace_changed", "caller_routing_unresolved", "self_target":
            detail = "The original routed caller, workspace, or non-self target no longer authorizes deletion. Nothing was deleted for this item."
            next = "Return to the original requesting session/workspace and inspect session_admin {op: scope_status}; exclude the caller itself."
            retryable = false
        case "batch_preflight_not_applied":
            detail = "Another requested ID failed authorization; this item was not processed."
            next = "Remove the self-target identified in this batch, then call cleanup_sessions again with only the remaining session_ids."
            retryable = false
        case "target_binding_changed", "target_state_unresolved":
            detail = "The target binding changed or became ambiguous before deletion; no deletion was invoked."
            next = "Inspect the target in the app and resolve its binding, then retry cleanup_sessions with its exact session_id."
            retryable = false
        case "not_mcp_originated":
            detail = "Administrative cleanup only deletes MCP-originated sessions."
            next = "Ask the user to delete this session in the app."
            retryable = false
        case "skipped_active":
            detail = "The session is active or has a pending follow-up; it was not deleted."
            next = "Use agent_run {op: wait, session_id: <this session_id>}; retry cleanup after the session becomes terminal."
            retryable = true
        case "already_absent":
            detail = "No session was found in the routed workspace; no deletion was necessary."
            next = "If another workspace was intended, route the call there; otherwise no action is required for this session_id."
            retryable = false
        case "resolution_failed":
            detail = "The session metadata or persisted payload could not be resolved; no deletion was committed."
            next = "Ask the user to inspect or repair the saved session in the app, then retry cleanup_sessions with this session_id."
            retryable = false
        case "local_cleanup_failed", "provider_cleanup_failed", "provider_cleanup_cancelled":
            detail = "The session was durably deleted, but subsequent local/provider cleanup did not complete."
            next = "Do not repeat deletion. Ask the user to inspect the remaining provider conversation or local references."
            retryable = false
        case "cancelled_before_processing", "cancelled_before_mutation", "cancelled_after_committed_deletion",
             "cancelled_after_mutation_started", "mutation_cancelled":
            detail = "Cancellation left this session unprocessed or without a committed deletion; committed siblings remain deleted."
            next = "Retry agent_manage {op: cleanup_sessions, session_ids: [<this session_id>]} in a new uncancelled call."
            retryable = true
        default:
            detail = "Deletion was not confirmed; the failure needs inspection before retry."
            next = "Ask the user to inspect the session and storage error, then retry cleanup_sessions with this session_id."
            retryable = false
        }
        item["code"] = .string(reason)
        item["subreason"] = .string(reason)
        item["detail"] = .string(detail)
        item["next_step"] = .string(next)
        item["retryable"] = .bool(retryable)
        return item
    }
}
