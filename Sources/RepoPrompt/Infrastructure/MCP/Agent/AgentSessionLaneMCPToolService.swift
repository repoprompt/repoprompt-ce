import Foundation
import MCP

/// Flat, bounded lane receipts. Failed durable admission never starts a provider.
enum AgentSessionLaneMCPToolService {
    typealias Destination = AgentSessionLaneDestination

    @MainActor
    static func resolveDestination(workspaceSelector: String?, callerWindow: WindowState) -> Destination? {
        resolveDestination(
            workspaceSelector: workspaceSelector,
            callerWindowID: callerWindow.windowID,
            callerWorkspaceID: callerWindow.workspaceManager.activeWorkspaceID
        ).destination
    }

    @MainActor
    static func resolveDestination(workspaceSelector: String?, callerWindowID: Int, callerWorkspaceID: UUID?) -> AgentSessionLaneDestinationResolution {
        let candidates = WindowStatesManager.shared.allWindows.compactMap { window -> Destination? in
            guard !window.isClosing, let workspace = window.workspaceManager.activeWorkspace else { return nil }
            return Destination(windowID: window.windowID, workspaceID: workspace.id, workspaceName: workspace.name)
        }
        return selectDestinationResult(
            candidates: candidates,
            workspaceSelector: workspaceSelector,
            callerWindowID: callerWindowID,
            callerWorkspaceID: callerWorkspaceID
        )
    }

    static func selectDestination(candidates: [Destination], workspaceSelector: String?, callerWindowID: Int) -> Destination? {
        selectDestinationResult(
            candidates: candidates,
            workspaceSelector: workspaceSelector,
            callerWindowID: callerWindowID,
            callerWorkspaceID: nil
        ).destination
    }

    static func selectDestinationResult(candidates: [Destination], workspaceSelector: String?, callerWindowID: Int, callerWorkspaceID: UUID?) -> AgentSessionLaneDestinationResolution {
        let matches: [Destination]
        if let workspaceSelector {
            matches = candidates.filter { candidate in
                if let id = UUID(uuidString: workspaceSelector) { return candidate.workspaceID == id }
                return AgentSessionLaneCreateRequest.canonicalSelector(candidate.workspaceName)
                    == AgentSessionLaneCreateRequest.canonicalSelector(workspaceSelector)
            }
            guard !matches.isEmpty else { return .unavailable(.selectorMatchedNone) }
        } else {
            let current = candidates.filter {
                $0.windowID == callerWindowID && (callerWorkspaceID == nil || $0.workspaceID == callerWorkspaceID)
            }
            matches = current.isEmpty ? candidates : current
            guard !matches.isEmpty else { return .unavailable(.callerWindowHasNoWorkspace) }
        }
        guard Set(matches.map(\.workspaceID)).count == 1 else { return .unavailable(.selectorAmbiguous) }
        let selected = matches.min { lhs, rhs in
            if (lhs.windowID == callerWindowID) != (rhs.windowID == callerWindowID) { return lhs.windowID == callerWindowID }
            return lhs.windowID < rhs.windowID
        }!
        return .available(selected)
    }

    static func refusal(_ reason: AgentSessionLaneCreateReceipt.Reason) -> Value {
        render(.refused(reason))
    }

    static func render(_ receipt: AgentSessionLaneCreateReceipt) -> Value {
        if receipt.result == .refused {
            if receipt.reason == .modelUnavailable {
                return .object([
                    "result": .string("model_unavailable"),
                    "subreason": .string("model_unavailable"),
                    "next_call": .object(["tool": .string("agent_manage"), "arguments": .object(["op": .string("list_agents")])]),
                    "hint": .string("Refresh agent_manage.list_agents in the destination window and retry with an exact available model_id, or omit model_id to use role defaults. No lane was allocated.")
                ])
            }
            if receipt.reason == .laneLimitReached {
                return .object([
                    "result": .string(AgentSessionLaneCreateReceipt.Reason.laneLimitReached.rawValue),
                    "subreason": .string("lane_limit_reached"),
                    "next_call": .object(["tool": .string("agent_session_link"), "arguments": .object(["op": .string("list")])]),
                    "lanes": .string("\(receipt.laneCount)/\(AgentSessionLanePolicy.agentSessionLaneMaximumCount)")
                ])
            }
            let reason = receipt.reason ?? .admissionUnstable
            let hint = switch reason {
            case .destinationUnavailable:
                "No unambiguous active destination was available, or it changed before allocation. Open the intended workspace in the app, then retry create_lane with its UUID in workspace if more than one destination remains. No lane was allocated."
            case .workspaceAdmissionRejected:
                "Workspace admission did not complete. Resolve the reported workspace saving or recovery condition in the app. Retry the original idempotency_key only after recovery has completed; requesting scope or changing the key does not repair persistence."
            case .scopeDenied:
                "The destination was resolved, but a live delegation scope's limit (sessions, depth or worktrees) or an unprovable session placement refused this creation. Lane creation needs no spawn capability. Call session_admin scope_status to see the limiting scope; if placement is unresolved, load or repair the affected sessions before retrying. No lane was allocated."
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
                "Call become_overseer from this exact routed session, then retry the operation when discovery is refreshed. No filler user turn is needed: for an existing target, become_overseer with session_id and optional message requests consent and automatically links/dispatches. Activation alone grants no target authority."
            case .addFailed:
                "Lane linking failed. Inspect the returned session_id and link it with session_admin link after resolving the oversight dashboard warning; do not allocate a replacement blindly."
            case .admissionUnstable:
                "Concurrent lane or session changes prevented stable admission. Wait for those operations to settle and retry with the same key."
            case .modelUnavailable, .laneLimitReached:
                "Refresh the lane inventory and available models before retrying."
            }
            var fields: [String: Value] = ["result": .string(reason.rawValue), "hint": .string(hint)]
            if case .creationRejected? = receipt.destinationFailure {
                // The destination was fine; the app refused to create the session. The detail says why.
                fields["hint"] = .string("The destination resolved, but the app refused to create the lane session; see detail. Resolve that condition before retrying the original idempotency_key. No lane was allocated.")
                fields["retryable"] = .bool(false)
            }
            if case let .admissionRejected(failure)? = receipt.destinationFailure {
                appendAdmissionFailure(failure, to: &fields)
            }
            if let detail = receipt.refusalDetail { fields["detail"] = .string(detail) }
            if fields["subreason"] == nil {
                fields["subreason"] = .string(reason == .destinationUnavailable ? (receipt.destinationFailure ?? .destinationChanged).subreason : receipt.admissionSubreason ?? reason.rawValue)
            }
            if let stage = receipt.refusalStage { fields["stage"] = .string(stage) }
            // A recovery call must change the refusing condition. Neither scope discovery nor
            // workspace listing repairs a save/host failure, and may be absent on this surface.
            if reason == .denied {
                fields["next_call"] = .object(["tool": .string("become_overseer"), "arguments": .object([:])])
            } else if reason == .roleUnavailable {
                fields["next_call"] = .object(["tool": .string("agent_manage"), "arguments": .object(["op": .string("list_agents")])])
            }
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
            if case let .admissionRejected(failure)? = receipt.destinationFailure {
                appendAdmissionFailure(failure, to: &fields)
                fields["detail"] = .string(failure.detail)
                fields["stage"] = .string("workspace_admission")
                fields["recovery_hint"] = .string(
                    "This key only replays this receipt. Complete workspace recovery in the app and inspect \(sessionID.uuidString); reuse that session if it remains. Allocate a replacement only after recovery confirms this identity was removed. No provider was started."
                )
            } else {
                fields["recovery_hint"] = .string(
                    "This key only replays this receipt. Retain \(sessionID.uuidString); after recovery, link it with ordinary add."
                )
            }
        }
        return .object(fields)
    }

    private static func appendAdmissionFailure(_ failure: AgentSessionLaneAdmissionFailure, to fields: inout [String: Value]) {
        fields["retryable"] = .bool(false)
        fields["save_result"] = .string(failure.saveResult)
        fields["failure_category"] = .string(failure.category)
        fields["working_committed"] = .bool(failure.workingCommitted)
        fields["subreason"] = .string(failure.reason)
        if let diagnostic = failure.domainDiagnostic {
            fields["authority_diagnostic"] = .string(String(diagnostic.prefix(160)))
        }
        if let code = failure.domainErrorCode { fields["authority_error"] = .string(code) }
        guard let retained = failure.retainedAdmission else { return }
        fields["tab_id"] = .string(retained.identity.tabID.uuidString)
        fields["workspace_id"] = .string(retained.identity.workspaceID.uuidString)
        let recoveryState = switch retained.recovery {
        case .recovered: "recovered"
        case .alreadyRecovered: "already_recovered"
        case .localOnly: "local_only"
        case .ownershipChanged: "ownership_changed"
        case .retryablePartial: "retryable_partial"
        case .failed: "failed"
        case .blockedManual: "blocked_manual"
        }
        fields["recovery_state"] = .string(recoveryState)
        switch retained.recovery {
        case let .failed(category), let .blockedManual(category):
            fields["recovery_category"] = .string(category)
        default: break
        }
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
