import Foundation
import MCP

/// Flat, bounded lane receipts. Allocation refusals never disclose a session ID.
enum AgentSessionLaneMCPToolService {
    struct Destination: Equatable {
        let windowID: Int
        let workspaceID: UUID
        let workspaceName: String
    }

    @MainActor
    static func resolveDestination(
        workspaceSelector: String?,
        callerWindow: WindowState
    ) -> Destination? {
        let candidates = WindowStatesManager.shared.allWindows.compactMap { window -> Destination? in
            guard !window.isClosing, let workspace = window.workspaceManager.activeWorkspace else {
                return nil
            }
            return Destination(
                windowID: window.windowID,
                workspaceID: workspace.id,
                workspaceName: workspace.name
            )
        }
        return selectDestination(
            candidates: candidates,
            workspaceSelector: workspaceSelector,
            callerWindowID: callerWindow.windowID
        )
    }

    static func selectDestination(
        candidates: [Destination],
        workspaceSelector: String?,
        callerWindowID: Int
    ) -> Destination? {
        let matches = candidates.filter { candidate in
            guard let workspaceSelector else { return candidate.windowID == callerWindowID }
            if let id = UUID(uuidString: workspaceSelector) { return candidate.workspaceID == id }
            return AgentSessionLaneCreateRequest.canonicalSelector(candidate.workspaceName)
                == AgentSessionLaneCreateRequest.canonicalSelector(workspaceSelector)
        }
        if workspaceSelector != nil, Set(matches.map(\.workspaceID)).count != 1 { return nil }
        return matches.min { lhs, rhs in
            let lhsIsCaller = lhs.windowID == callerWindowID
            let rhsIsCaller = rhs.windowID == callerWindowID
            if lhsIsCaller != rhsIsCaller { return lhsIsCaller }
            return lhs.windowID < rhs.windowID
        }
    }

    static func refusal(_ reason: String) -> Value {
        .object(["result": .string(reason)])
    }

    static func render(_ receipt: AgentSessionLaneCreateReceipt) -> Value {
        if receipt.result == .refused {
            if receipt.reason == .modelUnavailable {
                return .object([
                    "result": .string("model_unavailable"),
                    "hint": .string("Refresh agent_manage.list_agents in the destination window and retry with an exact available model_id, or omit model_id to use role defaults. No lane was allocated.")
                ])
            }
            if receipt.reason == .laneLimitReached {
                return .object([
                    "result": .string(AgentSessionLaneCreateReceipt.Reason.laneLimitReached.rawValue),
                    "lanes": .string("\(receipt.laneCount)/\(AgentSessionLanePolicy.agentSessionLaneMaximumCount)")
                ])
            }
            let reason = receipt.reason ?? .admissionUnstable
            let hint = switch reason {
            case .destinationUnavailable:
                "The selected workspace has no available active window, or its window/workspace changed before allocation. Open that workspace in a window, confirm its UUID with workspace tools, and retry. No lane was allocated."
            case .scopeDenied:
                "The destination was resolved, but scoped spawn admission was refused. Call session_admin scope_status to inspect spawn authority and limits. If placement is unresolved, load or repair the affected sessions before retrying; granting more capabilities does not repair provenance. No lane was allocated."
            case .persistenceUnavailable, .saveFailed:
                "Oversight storage is unavailable. Check the oversight dashboard's saving warning and retry after storage is available."
            case .hostUnavailable, .shuttingDown:
                "The app host is closing or unavailable. Retry from the requesting session after the app is ready."
            case .roleUnavailable:
                "Refresh agent_manage list_agents and retry with an available role or model_id. No lane was allocated."
            case .idempotencyConflict:
                "This idempotency_key belongs to different arguments. Use a new key for a different request."
            case .ledgerFull:
                "Too many lane creations are in flight or retained for this session. Wait for pending calls to settle before creating another lane."
            case .denied:
                "Call become_overseer, then retry next turn from the same session. Activation does not grant target authority."
            case .addFailed:
                "Lane linking failed. Inspect the returned session_id and link it with session_admin link after resolving the oversight dashboard warning; do not allocate a replacement blindly."
            case .admissionUnstable:
                "Concurrent lane or session changes prevented stable admission. Wait for those operations to settle and retry with the same key."
            case .modelUnavailable, .laneLimitReached:
                "Refresh the lane inventory and available models before retrying."
            }
            var fields: [String: Value] = ["result": .string(reason.rawValue), "hint": .string(hint)]
            if let detail = receipt.refusalDetail { fields["detail"] = .string(detail) }
            return .object(fields)
        }
        var fields: [String: Value] = [
            "result": .string(receipt.result == .created ? "created" : "creation_incomplete"),
            "linked": .bool(receipt.linked),
            "first_task": .string(firstTask(receipt.firstTask)),
            "lanes": .string("\(receipt.laneCount)/\(AgentSessionLanePolicy.agentSessionLaneMaximumCount)"),
            "duplicate": .bool(receipt.duplicate)
        ]
        if receipt.firstTask == .failed, let reason = receipt.firstTaskReason {
            fields["first_task_subreason"] = .string(reason)
        }
        if let sessionID = receipt.sessionID { fields["session_id"] = .string(sessionID.uuidString) }
        if let sessionName = receipt.sessionName { fields["session_name"] = .string(sessionName) }
        if let workspaceName = receipt.workspaceName { fields["workspace"] = .string(workspaceName) }
        if !receipt.linked, let reason = receipt.reason {
            fields["link_reason"] = .string(reason.rawValue)
        }
        if receipt.result == .creationIncomplete, let sessionID = receipt.sessionID {
            fields["recovery_hint"] = .string(
                "This key only replays this receipt. Retain \(sessionID.uuidString); after recovery, link it with ordinary add."
            )
        }
        return .object(fields)
    }

    static func render(_ outcome: AgentSessionLaneRetireOutcome) -> Value {
        switch outcome {
        case let .retired(sessionID):
            return .object(["result": .string("retired"), "session_id": .string(sessionID.uuidString)])
        case let .notRetired(sessionID, reason):
            var fields: [String: Value] = [
                "result": .string("not_retired"),
                "session_id": .string(sessionID.uuidString),
                "reason": .string(reason.wireReason)
            ]
            if let subreason = reason.subreason { fields["subreason"] = .string(subreason) }
            return .object(fields)
        case let .unlinkedNotStashed(sessionID):
            return .object([
                "result": .string("unlinked_not_stashed"),
                "session_id": .string(sessionID.uuidString)
            ])
        }
    }

    private static func firstTask(_ value: AgentSessionLaneCreateReceipt.FirstTask) -> String {
        switch value {
        case .none: "none"
        case .delivered: "delivered"
        case .queued: "queued"
        case .failed: "failed"
        }
    }
}
