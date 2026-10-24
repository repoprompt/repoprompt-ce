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
        let scopes = delegationScopes
        func refusal(_ code: String, subreason: String, detail: String) -> Value {
            Self.overseeInitialResult(
                result: "not_applied",
                code: code,
                subreason: subreason,
                detail: detail,
                observer: observer.sessionID,
                target: targetSessionID
            )
        }
        guard targetSessionID != observer.sessionID else {
            return refusal("link_refused", subreason: "self_monitor", detail: "A session cannot oversee itself. Choose a different target.")
        }
        let resolution = await WindowStatesManager.shared.resolveSavedOversightLocation(targetSessionID)
        if case let .failure(reason) = resolution {
            return refusal(
                "target_not_preparable",
                subreason: reason.rawValue,
                detail: "No approval card was created. Ask the user to resolve the exact saved target's missing, conflicting or unreadable state before retrying."
            )
        }
        guard !Task.isCancelled, await revalidateObserver(endpoint: observer) else {
            return refusal("request_refused", subreason: "caller_changed", detail: "The requesting session's exact binding changed. Reissue from its current session.")
        }
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
            return refusal(
                "request_refused",
                subreason: Self.overseeRequestRefusalCode(requested),
                detail: "The exact-target request was refused before any task was started. Inspect scope_status and correct the request before retrying."
            )
        }
        // A retained receipt is a fact about this exact task, not renewed consent. Even revocation
        // must not turn an unchanged key into a second delivery.
        if let outcome = scopes.overseeInitialOutcome(requestID: request.id) { return outcome }
        scopes.beginOverseeInitialOutcome(requestID: request.id)
        _ = scopes.installOverseeContinuation(requestID: request.id) { [weak self] scope in
            guard let self else {
                scopes.completeOverseeInitialOutcome(requestID: request.id, value: Self.overseeInitialResult(
                    result: "not_applied", code: "runtime_unavailable", subreason: "bridge_released",
                    detail: "The approved task could not start because its runtime ended.",
                    observer: observer.sessionID, target: targetSessionID, requestID: request.id, scopeID: scope.id
                ))
                return
            }
            await continueTargetedOversight(
                observer: observer,
                targetSessionID: targetSessionID,
                message: message,
                scopeID: scope.id,
                requestID: request.id
            )
        }
        _ = scopes.approveWithStandingConsent(requestID: request.id)
        _ = scopes.continueOverseeWithExistingConsent(requestID: request.id)
        let state = scopes.request(id: request.id, requesterSessionID: observer.sessionID)?.state ?? request.state
        if case .granted = state {
            // Join only preparation/link/initial delivery, never the ongoing status watch. A
            // standing grant is not a successful assignment until these effects actually settle.
            let outcome = await scopes.waitForOverseeInitialOutcome(requestID: request.id)
            guard await revalidateObserver(endpoint: observer) else {
                return Self.overseeInitialResult(
                    result: "partial",
                    code: "caller_changed",
                    subreason: "outcome_release_fence",
                    detail: "The approved task may have committed, but the requesting binding changed before its outcome could be returned. Do not resend the task.",
                    observer: observer.sessionID,
                    target: targetSessionID,
                    requestID: request.id
                )
            }
            return outcome
        }
        guard state == .pending else {
            return Self.overseeInitialResult(
                result: "not_applied",
                code: "approval_not_granted",
                subreason: state.label,
                detail: "No new task was started. Inspect scope_status before making a fresh request.",
                observer: observer.sessionID,
                target: targetSessionID,
                requestID: request.id
            )
        }
        return .object([
            "result": .string("approval_requested"), "request_id": .string(request.id.uuidString),
            "session_id": .string(targetSessionID.uuidString), "state": .string("pending"),
            "capabilities": .array(["observe", "control", "restructure"].map(Value.string)),
            "continuation": .string("The app will prepare this saved target, link it, and deliver the requested task after this one approval. Do not duplicate the task or request another capability card. Approval, denial and task status resume you automatically.")
        ])
    }

    private static func overseeInitialResult(
        result: String, code: String, subreason: String, detail: String,
        observer: UUID, target: UUID, requestID: UUID? = nil, scopeID: UUID? = nil,
        linkID: UUID? = nil, linkCommitted: Bool = false, receipt: DomainAgentSessionLinkSendReceipt? = nil,
        retryable: Bool = false
    ) -> Value {
        var object: [String: Value] = [
            "result": .string(result), "code": .string(code), "subreason": .string(subreason),
            "detail": .string(detail), "session_id": .string(target.uuidString),
            "observer_session_id": .string(observer.uuidString), "link_committed": .bool(linkCommitted),
            "affected_session_ids": .array([.string(observer.uuidString), .string(target.uuidString)]),
            "next_call": .string(
                result == "applied"
                    ? "agent_session_link {op:\"poll\", session_ids:[\"\(target.uuidString)\"]}"
                    : "session_admin {op:\"scope_status\"}"
            ),
            "retryable": .bool(retryable)
        ]
        if let requestID { object["request_id"] = .string(requestID.uuidString) }
        if let scopeID { object["scope_id"] = .string(scopeID.uuidString) }
        if let linkID { object["link_id"] = .string(linkID.uuidString) }
        if let receipt {
            object["target_item_id"] = .string(receipt.targetItemID)
            object["delivery_state"] = .string(receipt.deliveryState.rawValue)
        }
        return .object(object)
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
            if case let .string(code) = item["subreason"], AgentSessionLinkResolveFailure(rawValue: code) != nil { return code }
            if case let .string(code) = item["code"], ["scope_revoked", "self_link", "lease_revoked", "authorization_revoked"].contains(code) { return code }
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
        var linkCommitted = false
        var linkID: UUID?
        var acceptedReceipt: DomainAgentSessionLinkSendReceipt?
        func notify(_ result: String, continuing: Bool = false, deliveredNothing: Bool = false) {
            scopes.notifyOverseeContinuation(
                sessionID: observer.sessionID, tabID: observer.tabID, requestID: requestID,
                result: "oversee target=\(targetSessionID.uuidString); \(result)", continuing: continuing,
                deliveredNothing: deliveredNothing
            )
        }
        func finish(_ code: String, subreason: String, detail: String, applied: Bool = false, retryable: Bool = false, continuing: Bool = false) {
            let result = applied ? "applied" : (linkCommitted || acceptedReceipt != nil ? "partial" : "not_applied")
            let value = Self.overseeInitialResult(
                result: result,
                code: code,
                subreason: subreason,
                detail: detail,
                observer: observer.sessionID,
                target: targetSessionID,
                requestID: requestID,
                scopeID: scopeID,
                linkID: linkID,
                linkCommitted: linkCommitted,
                receipt: acceptedReceipt,
                retryable: retryable
            )
            scopes.completeOverseeInitialOutcome(requestID: requestID, value: value)
            // Only closed app codes/static detail enter this authority notice, never handler text.
            notify("\(code); result=\(result); subreason=\(subreason); detail=\(detail); link_committed=\(linkCommitted); link_id=\(linkID?.uuidString ?? "unavailable"); next_call=session_admin {op:\"scope_status\"}; retryable=\(retryable)", continuing: continuing, deliveredNothing: result == "not_applied")
        }
        func consentIsCurrent() -> Bool {
            scopes.reconcileGlobalAutoApprove()
            return !Task.isCancelled && scopes.linkConsent.permits(
                scopeID: scopeID, observer: observer.sessionID, target: targetSessionID, at: Date()
            )
        }
        func interruptionCode() -> String {
            if !scopes.linkConsent.permits(scopeID: scopeID, observer: observer.sessionID, target: targetSessionID, at: Date()) { return "scope_revoked" }
            return Task.isCancelled ? "continuation_cancelled" : "caller_changed"
        }
        let required: Set<DomainDelegationScopeCapability> = [.observe, .control, .restructure]
        if let record = scopes.record(id: scopeID), record.isActive {
            let missing = required.subtracting(record.grant.capabilities)
            if !missing.isEmpty {
                finish(
                    "scope_capability_missing",
                    subreason: "missing_capabilities",
                    detail: "missing_capabilities=\(missing.map(\.rawValue).sorted().joined(separator: ",")); the user's reduced grant was honored; nothing delivered"
                )
                return
            }
        }
        guard consentIsCurrent(), await revalidateObserver(endpoint: observer), consentIsCurrent() else {
            finish(interruptionCode(), subreason: "before_link", detail: "The current caller/consent fence refused linking; nothing delivered.")
            return
        }
        do {
            let outcome = try await sessionAdministrationFrontDoor.perform(AgentSessionAdministrationRequest(
                operation: .adminLink, caller: .agentSession(observer.sessionID), callerTabID: observer.tabID,
                scopeID: scopeID, targetSessionIDs: [targetSessionID], idempotencyKey: "oversee-link:\(requestID.uuidString)"
            ))
            guard case let .completed(value) = outcome,
                  case let .array(items) = value.objectValue?["items"],
                  case let .string(result) = items.first?.objectValue?["result"], ["linked", "already_linked"].contains(result)
            else {
                let code = Self.overseeLinkRefusalCode(outcome)
                finish("link_refused", subreason: code, detail: "link_refused: \(code); nothing delivered. Inspect scope_status and resolve this refusal before requesting a new task.")
                return
            }
            linkCommitted = true
            linkID = await delegationActiveLink(observerSessionID: observer.sessionID, targetSessionID: targetSessionID)?.linkID
        } catch {
            finish("link_failed", subreason: "host_error", detail: "The link handler failed before it returned a committed outcome; nothing delivered. Inspect scope_status and link state before retrying.")
            return
        }
        #if DEBUG
            await test_afterTargetedLink?()
        #endif
        guard consentIsCurrent(), await revalidateObserver(endpoint: observer), consentIsCurrent() else {
            finish(interruptionCode(), subreason: "after_link", detail: "The link committed, but authority or the caller changed before delivery. No message was sent. Inspect scope_status and the link before making a new request.")
            return
        }
        guard let message else {
            finish("linked", subreason: "link_committed", detail: "The target is linked and ready; no provider was started merely to link it.", applied: true)
            return
        }
        let authorization = await authorizeTarget(operation: .monitorSteer, observerEndpoint: observer, targetSessionID: targetSessionID)
        guard consentIsCurrent() else {
            finish(interruptionCode(), subreason: "before_delivery", detail: "The link committed but consent ended before delivery. Nothing was delivered; inspect scope_status before making a new task request.")
            return
        }
        guard case let .success(target) = authorization else {
            finish("control_unavailable", subreason: "steer_authorization_refused", detail: "The link committed, but the current link/endpoint fence refused management. Nothing was delivered. Inspect scope_status and restore management before a new task request.")
            return
        }
        let before = await targetState(for: target.lease)
        guard consentIsCurrent(), await revalidateObserver(endpoint: observer), consentIsCurrent() else {
            finish(interruptionCode(), subreason: "delivery_entry", detail: "The link committed, but the final caller/consent fence refused delivery. Nothing was delivered. Inspect scope_status before a new task request.")
            return
        }
        let delivery = await steer(target: target, message: message, idempotencyKey: "oversee-send:\(requestID.uuidString)")
        guard case let .receipt(receipt) = delivery else {
            finish("delivery_refused", subreason: Self.overseeDeliveryRefusalCode(delivery), detail: "The link committed but message delivery was refused. Inspect scope_status and target state before a fresh task request; an unchanged retry only returns this receipt.")
            return
        }
        acceptedReceipt = receipt
        #if DEBUG
            await test_afterTargetedDelivery?()
        #endif
        guard consentIsCurrent() else {
            finish("delivery_accepted_scope_revoked", subreason: interruptionCode(), detail: "Delivery was accepted before authority ended. The task may still run or be saved. Reauthorize observation and inspect the target transcript; do not resend the message.")
            return
        }
        guard receipt.deliveryState != .persisted, receipt.deliveryState != .runStartFailed else {
            finish("message_saved_not_dispatched", subreason: receipt.deliveryState.rawValue, detail: "The message was saved but dispatch did not succeed. Inspect the target failure through poll/read; do not resend the message.")
            return
        }
        let watch = await authorizeTarget(operation: .monitorWait, observerEndpoint: observer, targetSessionID: targetSessionID)
        guard case let .success(watching) = watch, consentIsCurrent() else {
            finish("watch_unavailable", subreason: "post_delivery_watch_fence", detail: "Delivery was accepted, but automatic observation could not start. Inspect scope_status, restore observation and read the target; do not resend the message.")
            return
        }
        finish("task_delivered", subreason: receipt.deliveryState.rawValue, detail: "Delivery was accepted; automatically watching for a reply or pending interaction.", applied: true, continuing: true)
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
            guard consentIsCurrent() else {
                notify("watch_ended; result=partial; code=\(interruptionCode()); subreason=after_wait; detail=Delivery was already accepted; restore observation and read the target, do not resend; retryable=false; next_call=session_admin {op:\"scope_status\"}")
                return
            }
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
        notify("watch_ended; result=partial; code=\(interruptionCode()); subreason=watch_loop; detail=Delivery was already accepted; restore observation and read the target, do not resend; retryable=false; next_call=session_admin {op:\"scope_status\"}")
    }
}
