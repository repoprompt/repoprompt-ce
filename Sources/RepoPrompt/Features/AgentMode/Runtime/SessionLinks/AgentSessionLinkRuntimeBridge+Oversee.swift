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
    ) -> Value {
        let scopes = delegationScopes
        let requested = scopes.requestScope(
            requesterSessionID: observer.sessionID, requesterTabID: observer.tabID,
            kind: .session(targetSessionID: targetSessionID),
            capabilities: [.observe, .control, .restructure], guardrails: .init(),
            reason: message == nil
                ? "Oversee only this target: view, manage and establish its link."
                : "Oversee only this target, establish its link, and deliver the requested message: \(message!)",
            idempotencyKey: idempotencyKey
        )
        guard case let .success(request) = requested else {
            return .object([
                "result": .string("request_refused"),
                "reason": .string(String(describing: requested)),
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
        let reused = scopes.continueOverseeWithExistingConsent(requestID: request.id)
        let currentState = scopes.request(id: request.id, requesterSessionID: observer.sessionID)?.state ?? request.state
        let result = currentState == .pending ? "approval_requested" : (reused ? "continuing_approved_request" : "request_replayed")
        return .object([
            "result": .string(result),
            "request_id": .string(request.id.uuidString),
            "session_id": .string(targetSessionID.uuidString),
            "capabilities": .array(["observe", "control", "restructure"].map(Value.string)),
            "state": .string(String(describing: currentState)),
            "continuation": .string("The app will prepare this saved target, link it, and deliver the requested task after this one approval. Do not ask for go, open its tab, duplicate the task, or request another capability card. Approval, denial and task status resume you automatically.")
        ])
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
                // The real handler's refusal includes the preparation subreason and next call.
                notify("link_refused: \(String(describing: outcome).prefix(1600)); nothing delivered")
                return
            }
        } catch {
            notify("link_failed:\(String(describing: type(of: error))); next_call=session_admin {op:\"scope_status\"}; nothing delivered")
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
            notify("delivery_refused: \(String(describing: delivery).prefix(1000)); next_call=session_admin {op:\"scope_status\"}")
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
        var cursor = before?.waitCursor
        let deadline = Date().addingTimeInterval(60)
        while consentIsCurrent(), Date() < deadline {
            let update = await wait(
                requests: [.init(lease: watching.lease, cursor: cursor)], until: .change,
                timeoutSeconds: max(0.01, deadline.timeIntervalSinceNow)
            )
            guard consentIsCurrent() else { return }
            if let state = update.targets.first {
                cursor = state.waitCursor
                if state.snapshot.hasPendingInteraction {
                    notify("target_waiting_for_approval; inspect agent_session_link poll/read now; no permission was auto-granted")
                    return
                }
                if state.snapshot.idleForSend, state.snapshot.lastActivityAt > (before?.snapshot.lastActivityAt ?? .distantPast) {
                    notify("target_idle_with_new_activity; inspect agent_session_link poll/read for the requested result")
                    return
                }
            }
            if case .changed = update.outcome { continue }
            notify("watch_status=\(String(describing: update.outcome)); inspect agent_session_link poll/wait and continue the assigned work")
            return
        }
        if consentIsCurrent() { notify("task_still_pending; inspect agent_session_link poll/wait and continue the assigned work") }
    }
}
