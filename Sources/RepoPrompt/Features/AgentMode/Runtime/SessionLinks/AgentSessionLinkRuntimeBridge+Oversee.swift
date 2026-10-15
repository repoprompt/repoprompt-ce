import Foundation
import MCP
import RepoPromptDomainRuntime

extension AgentSessionLinkRuntimeBridge {
    /// Starts from the already route-proven bootstrap tool. Arguments request a task, never consent.
    /// The one real approval owns continuation; it does not depend on a provider refreshing its
    /// current turn's tool catalog. All effects still enter the ordinary administration/link owners.
    func requestTargetedOversight(
        observer: DomainAgentSessionLinkEndpointIdentity,
        targetSessionID: UUID,
        message: String?,
        idempotencyKey: String
    ) async -> Value {
        let resolution = await WindowStatesManager.shared.resolveSavedOversightLocation(targetSessionID)
        if case let .failure(reason) = resolution {
            return .object([
                "result": .string("target_not_preparable"), "subreason": .string(reason.rawValue),
                "next_call": .string("session_admin {op:\"scope_status\"}"),
                "message": .string("No approval card was created. Ask the user to check whether this exact saved session was deleted, moved, has conflicting copies, or has unreadable saved state. Historical sessions, stashed tabs and inactive workspaces do not require a UI visit. Do not retry an unchanged refusal.")
            ])
        }
        guard !Task.isCancelled, await revalidateObserver(endpoint: observer) else {
            return .object(["result": .string("request_refused"), "reason": .string("caller_changed")])
        }
        let scopes = delegationScopes
        let requested = scopes.requestScope(
            requesterSessionID: observer.sessionID, requesterTabID: observer.tabID,
            kind: .session(targetSessionID: targetSessionID),
            capabilities: [.observe, .control, .restructure], guardrails: .init(),
            reason: message == nil
                ? "Oversee only this target: view, manage and establish its link."
                : "Oversee only this target, establish its link, and deliver the requested message: \(message!)",
            idempotencyKey: idempotencyKey, reusePendingOnly: true
        )
        guard case let .success(request) = requested else {
            return .object([
                "result": .string("request_refused"),
                "reason": .string(Self.overseeRequestRefusalCode(requested)),
                "next_call": .string("session_admin {op:\"scope_status\"}")
            ])
        }
        // Replays cannot replace the task attached to an existing card, or send it twice.
        _ = scopes.installOverseeContinuation(requestID: request.id) { [weak self] scope in
            guard let self else { return }
            await continueTargetedOversight(
                observer: observer, targetSessionID: targetSessionID, message: message,
                scopeID: scope.id, requestID: request.id
            )
        }
        // Standing user consent ("Grant all for this session" or the global setting) approves
        // through the same path as the card, after the continuation is installed.
        let autoApproved = scopes.approveWithStandingConsent(requestID: request.id)
        let reused = autoApproved || scopes.continueOverseeWithExistingConsent(requestID: request.id)
        let currentState = scopes.request(id: request.id, requesterSessionID: observer.sessionID)?.state ?? request.state
        let result = currentState == .pending ? "approval_requested" : (reused ? "continuing_approved_request" : "request_replayed")
        let state = switch currentState {
        case .pending: "pending"
        case .granted: "granted"
        case .denied: "denied"
        case .cancelled: "cancelled"
        }
        let continuation = currentState == .pending
            ? "The app will prepare this saved target, link it, and deliver the requested task after this one approval. Do not ask for go, open its tab, duplicate the task, or request another capability card. Approval, denial and task status resume you automatically."
            : reused
            ? "An approved continuation owns this task: it is running or finished within the last 30 seconds. This request_id identifies it; no duplicate task is started by a retry. Automatic notices report progress; inspect agent_session_link poll/read for its status."
            : "This request is \(state). No new task was started by this replay. Inspect scope_status before making a fresh request."
        return .object([
            "result": .string(result),
            "request_id": .string(request.id.uuidString),
            "session_id": .string(targetSessionID.uuidString),
            "capabilities": .array(["observe", "control", "restructure"].map(Value.string)),
            "state": .string(state),
            "continuation": .string(continuation)
        ])
    }

    static func overseeRequestRefusalCode(_ result: Result<DelegationScopeRequest, DelegationScopeRequestError>) -> String {
        switch result {
        case .success: "not_refused"
        case let .failure(.invalid(reason)): reason.diagnosticLabel
        case .failure(.idempotencyConflict): "idempotency_conflict"
        case .failure(.tooManyPending): "too_many_pending"
        }
    }

    /// Only wire-stable codes cross into a trusted app notice, never arbitrary handler detail.
    static func overseeLinkRefusalCode(_ outcome: AgentSessionAdministrationOutcome) -> String {
        switch outcome {
        case let .denied(reason, _): return reason.diagnosticLabel
        case .pendingConfirmation: return "confirmation_required"
        case .scopeSelectionRequired: return "scope_id_required"
        case .idempotencyConflict: return "idempotency_conflict"
        case .tooManyPendingConfirmations: return "too_many_pending_confirmations"
        case .notImplemented: return "not_implemented"
        case let .completed(value):
            guard case let .array(items) = value.objectValue?["items"], let item = items.first?.objectValue else { return "invalid_link_result" }
            if case let .string(detail) = item["detail"], let code = detail.split(separator: ":", maxSplits: 1).first {
                let allowed: Set = ["target_missing", "target_unloaded_unpreparable", "target_ambiguous", "target_binding_changed", "target_saved_state_unreadable", "observer_changed", "source_scope_unavailable"]
                if allowed.contains(String(code)) { return String(code) }
            }
            return "link_not_applied"
        }
    }

    static func overseeDeliveryRefusalCode(_ outcome: SendOutcome) -> String {
        switch outcome {
        case .receipt: "accepted"
        case let .blocked(reason): reason.rawValue
        case let .rejected(reason): reason.rawValue
        case .workflowUnavailable: "workflow_unavailable"
        }
    }

    private func continueTargetedOversight(
        observer: DomainAgentSessionLinkEndpointIdentity, targetSessionID: UUID,
        message: String?, scopeID: UUID, requestID: UUID
    ) async {
        let scopes = delegationScopes
        func notify(_ result: String, continuing: Bool = false) {
            scopes.notifyOverseeContinuation(
                sessionID: observer.sessionID, tabID: observer.tabID, requestID: requestID,
                result: "oversee target=\(targetSessionID.uuidString); \(result)", continuing: continuing
            )
        }
        func consentIsCurrent() -> Bool {
            !Task.isCancelled && scopes.linkConsent.permits(
                scopeID: scopeID, observer: observer.sessionID, target: targetSessionID, at: Date()
            )
        }
        let required: Set<DomainDelegationScopeCapability> = [.observe, .control, .restructure]
        if let record = scopes.record(id: scopeID), record.isActive {
            let missing = required.subtracting(record.grant.capabilities)
            if !missing.isEmpty {
                notify("scope_capability_missing; missing_capabilities=\(missing.map(\.rawValue).sorted().joined(separator: ",")); the user's reduced grant was honored; next_call=session_admin {op:\"scope_status\"}; nothing delivered")
                return
            }
        }
        guard consentIsCurrent(), await revalidateObserver(endpoint: observer) else {
            notify("caller_changed_or_scope_revoked; next_call=session_admin {op:\"scope_status\"}; nothing delivered")
            return
        }
        do {
            let outcome = try await sessionAdministrationFrontDoor.perform(AgentSessionAdministrationRequest(
                operation: .adminLink, caller: .agentSession(observer.sessionID), callerTabID: observer.tabID,
                scopeID: scopeID, targetSessionIDs: [targetSessionID],
                idempotencyKey: "oversee-link:\(requestID.uuidString)"
            ))
            guard case let .completed(value) = outcome,
                  case let .object(object) = value, case let .array(items) = object["items"],
                  case let .object(item) = items.first,
                  case let .string(result) = item["result"], ["linked", "already_linked"].contains(result)
            else {
                notify("link_refused: \(Self.overseeLinkRefusalCode(outcome)); next_call=session_admin {op:\"scope_status\"}; nothing delivered")
                return
            }
        } catch {
            notify("link_failed:host_error; next_call=session_admin {op:\"scope_status\"}; nothing delivered")
            return
        }
        guard consentIsCurrent(), await revalidateObserver(endpoint: observer) else { return }
        guard let message else { notify("linked; ready; no provider was started to link")
            return
        }
        // Steer is the managed assignment path for both idle and running targets; it preserves the
        // final management/identity fence and exactly-once ledger, not an unscoped send shortcut.
        guard case let .success(target) = await authorizeTarget(
            operation: .monitorSteer, observerEndpoint: observer, targetSessionID: targetSessionID
        ), consentIsCurrent() else {
            notify("control_unavailable; next_call=session_admin {op:\"scope_status\"}; nothing delivered")
            return
        }
        let before = await targetState(for: target.lease)
        let delivery = await steer(target: target, message: message, idempotencyKey: "oversee-send:\(requestID.uuidString)")
        guard case let .receipt(receipt) = delivery else {
            notify("delivery_refused: \(Self.overseeDeliveryRefusalCode(delivery)); next_call=session_admin {op:\"scope_status\"}")
            return
        }
        guard consentIsCurrent() else { return }
        guard receipt.deliveryState != .persisted, receipt.deliveryState != .runStartFailed else {
            notify("message_saved_not_dispatched; delivery_state=\(receipt.deliveryState.rawValue); inspect agent_session_link poll/read for the exact target failure; do not send the message again")
            return
        }
        notify("task_delivered; delivery_state=\(receipt.deliveryState.rawValue); automatically watching for reply or pending interaction", continuing: true)
        // Event-driven, bounded status handoff. The notice starts a real requester turn with the
        // current tools; target text is never inserted into an app-authored authority notice.
        guard case let .success(watching) = await authorizeTarget(
            operation: .monitorWait, observerEndpoint: observer, targetSessionID: targetSessionID
        ), consentIsCurrent() else { return }
        #if DEBUG
            test_activeOverseeWatches += 1
            defer { test_activeOverseeWatches -= 1 }
        #endif
        var cursor = before?.waitCursor
        var deadline = overseeWatchNow().addingTimeInterval(60)
        while consentIsCurrent() {
            if overseeWatchNow() >= deadline {
                notify("task_still_pending; automatic watch remains active; no user input is needed", continuing: true)
                deadline = overseeWatchNow().addingTimeInterval(60)
            }
            let update = await wait(
                requests: [.init(lease: watching.lease, cursor: cursor)], until: .change,
                timeoutSeconds: max(0.01, deadline.timeIntervalSince(overseeWatchNow()))
            )
            guard consentIsCurrent() else { return }
            if let state = update.targets.first {
                cursor = state.waitCursor
                if state.snapshot.lastActivityAt > (before?.snapshot.lastActivityAt ?? .distantPast) {
                    switch state.snapshot.board.runOutcome {
                    case .failed:
                        notify("target_failed_with_new_activity; inspect agent_session_link poll/read for the task failure")
                        return
                    case .cancelled:
                        notify("target_cancelled_with_new_activity; inspect agent_session_link poll/read for the task outcome")
                        return
                    case .completed:
                        notify("target_idle_with_new_activity; inspect agent_session_link poll/read for the requested result")
                        return
                    default: break
                    }
                }
                if state.snapshot.hasPendingInteraction {
                    notify("target_waiting_for_approval; inspect agent_session_link poll/read now; no permission was auto-granted", continuing: true)
                    continue
                }
                if state.snapshot.idleForSend, state.snapshot.lastActivityAt > (before?.snapshot.lastActivityAt ?? .distantPast) {
                    notify("target_idle_with_new_activity; inspect agent_session_link poll/read for the requested result")
                    return
                }
            }
            if case .changed = update.outcome { continue }
            if update.outcome == .timedOut {
                // Sixty seconds bounds one wait, not ownership of the assigned task. Keep the
                // app-owned continuation subscribed until a result/interaction or consent ends.
                notify("task_still_pending; automatic watch remains active; no user input is needed", continuing: true)
                deadline = overseeWatchNow().addingTimeInterval(60)
                continue
            }
            notify("watch_status=requires_poll; inspect agent_session_link poll/wait and continue the assigned work")
            return
        }
    }
}
