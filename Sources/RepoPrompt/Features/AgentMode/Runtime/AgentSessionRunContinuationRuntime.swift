import Foundation
import RepoPromptInstrumentation

/// Owns follow-up producers and recovery, not a second run lifecycle. Each admitted producer
/// retains its request's startup composition until settlement; presentation is not its task owner.
@MainActor
final class AgentSessionRunContinuationRuntime {
    struct Launch {
        let start: @MainActor (AgentTabSession, AgentTabSession.PendingInstruction, AgentRunStartOutcomeRecorder) async -> Void
    }

    private weak var scope: AgentSessionRuntimeStore.Scope?
    private var pendingStarts: [ObjectIdentifier: [UUID: Task<Void, Never>]] = [:]
    var hasPendingStarts: Bool {
        !pendingStarts.isEmpty
    }

    func hasPendingStarts(for session: AgentTabSession) -> Bool {
        pendingStarts[ObjectIdentifier(session)]?.isEmpty == false
    }

    #if DEBUG
        var test_beforeScheduledACPFollowUpStart: (@MainActor () async -> Void)?
        var test_didFinishScheduledACPFollowUpStart: (@MainActor () -> Void)?
    #endif

    init(scope: AgentSessionRuntimeStore.Scope) {
        self.scope = scope
    }

    func makeRunHooks(prepareLaunch: @escaping () -> Launch?) -> AgentModeRunService.RunContinuationHooks {
        makeRunHooks(prepareSessionLaunch: { _ in prepareLaunch() })
    }

    /// Capture the originating command before enqueueing a producer, not after its suspension.
    func makeRunHooks(prepareSessionLaunch: @escaping (AgentTabSession) -> Launch?) -> AgentModeRunService.RunContinuationHooks {
        .init(
            startFollowUpRun: { [self] session, instruction in
                if session.selectedAgent.acpProviderID != nil {
                    scheduleTypedACPFollowUp(session: session, instruction: instruction, launch: prepareSessionLaunch(session))
                } else {
                    let instruction = instruction.retainingStopFence(instruction.stopFence ?? AgentRunStartStopFence(session: session))
                    guard let owner = scope else { return }
                    let launch = prepareSessionLaunch(session)
                    enqueue(owner: owner, session: session) { [self] in
                        await performFollowUp(session: session, instruction: instruction, launch: launch)
                    }
                }
            },
            startTypedACPFollowUpRun: { [self] session, instruction in
                scheduleTypedACPFollowUp(session: session, instruction: instruction, launch: prepareSessionLaunch(session))
            },
            signalMCPInstructionDelivered: { [self] session in
                await scope?.mcp.signalMCPInstructionDelivered(for: session)
            }
        )
    }

    /// Cancelled waiters still join the originating producers. Task cancellation is not a drain receipt.
    func drainPendingStarts(for session: AgentTabSession? = nil) async {
        guard let owner = scope else { return }
        defer { withExtendedLifetime(owner) {} }
        let identity = session.map(ObjectIdentifier.init)
        while true {
            let task = if let identity {
                pendingStarts[identity]?.values.first
            } else {
                pendingStarts.values.first?.values.first
            }
            guard let task else { return }
            await task.value
        }
    }

    @discardableResult
    private func enqueue(owner: AgentSessionRuntimeStore.Scope, session: AgentTabSession, operation: @escaping () async -> Void) -> Task<Void, Never> {
        let identity = ObjectIdentifier(session)
        let id = UUID()
        let task = Task { [self, owner] in
            defer {
                pendingStarts[identity]?.removeValue(forKey: id)
                if pendingStarts[identity]?.isEmpty == true { pendingStarts.removeValue(forKey: identity) }
                owner.noteSettlementChanged()
                withExtendedLifetime(owner) {}
            }
            await operation()
        }
        pendingStarts[identity, default: [:]][id] = task
        return task
    }

    func scheduleTypedACPFollowUp(
        session: AgentTabSession,
        instruction: AgentTabSession.PendingInstruction,
        capturedStopFence: AgentRunStartStopFence? = nil,
        launch: Launch?
    ) {
        guard let owner = scope else { return }
        let stopFence = capturedStopFence ?? instruction.stopFence ?? AgentRunStartStopFence(session: session)
        guard owner.sessions[session.tabID] === session, !owner.hasReleasedWriterClaims,
              !owner.isRetiring, stopFence.permitsStart(of: session)
        else {
            if owner.sessions[session.tabID] === session,
               stopFence.binding == session.persistentSessionBindingIdentity,
               let draft = instruction.localDraftText
            {
                restore(draft, session: session, owner: owner, reason: "cancelled start")
            }
            return
        }
        session.mcpFollowUpRunPending = true
        if var scheduled = session.scheduledACPFollowUp {
            // The first producer owns composition for the whole batch. Appended instructions
            // retain their individual Stop fences, not a second launcher or task owner.
            scheduled.queuedInstructions.append(.init(instruction: instruction, stopFence: stopFence))
            session.scheduledACPFollowUp = scheduled
            session.isDirty = true
            owner.presentation.bindingChanged(session)
            owner.persistence.scheduleSave(for: session)
            return
        }
        let scheduled = AgentTabSession.ScheduledACPFollowUp(id: UUID(), instruction: instruction, stopFence: stopFence)
        session.scheduledACPFollowUp = scheduled
        enqueue(owner: owner, session: session) { [self] in
            #if DEBUG
                defer { test_didFinishScheduledACPFollowUpStart?() }
                await test_beforeScheduledACPFollowUpStart?()
            #endif
            guard session.scheduledACPFollowUp?.id == scheduled.id else { return }
            let outcome = AgentRunStartOutcomeRecorder()
            if owner.sessions[session.tabID] === session, !owner.isRetiring,
               !owner.hasReleasedWriterClaims, stopFence.permitsStart(of: session)
            {
                await launch?.start(session, instruction.retainingStopFence(stopFence), outcome)
            }
            guard let settled = session.scheduledACPFollowUp, settled.id == scheduled.id else { return }
            session.scheduledACPFollowUp = nil
            if outcome.outcome.didStart {
                let eligible = settled.queuedInstructions.filter { $0.stopFence.permitsStart(of: session) }
                let cancelledDrafts = settled.queuedInstructions
                    .filter { !$0.stopFence.permitsStart(of: session) }
                    .filter { $0.stopFence.binding == session.persistentSessionBindingIdentity }
                    .compactMap(\.instruction.localDraftText)
                if owner.sessions[session.tabID] === session, !cancelledDrafts.isEmpty {
                    restore(cancelledDrafts.joined(separator: "\n"), session: session, owner: owner, reason: "cancelled start")
                }
                if session.runState.isActive {
                    session.pendingInstructions.append(contentsOf: eligible.map { $0.instruction.retainingStopFence($0.stopFence) })
                } else {
                    for next in eligible {
                        scheduleTypedACPFollowUp(session: session, instruction: next.instruction, capturedStopFence: next.stopFence, launch: launch)
                    }
                }
            } else if owner.sessions[session.tabID] === session {
                let drafts = ([AgentTabSession.ScheduledACPFollowUp.QueuedInstruction(
                    instruction: settled.instruction, stopFence: settled.stopFence
                )] + settled.queuedInstructions)
                    .filter { $0.stopFence.binding == session.persistentSessionBindingIdentity }
                    .compactMap(\.instruction.localDraftText)
                if !drafts.isEmpty {
                    restore(drafts.joined(separator: "\n"), session: session, owner: owner, reason: "failed start")
                }
            }
            if session.scheduledACPFollowUp == nil {
                session.mcpFollowUpRunPending = false
                owner.mcp.handleObservedMCPStateChange(for: session)
            }
        }
    }

    func startFollowUp(
        session: AgentTabSession,
        instruction: AgentTabSession.PendingInstruction,
        launch: Launch?
    ) async {
        guard let owner = scope else { return }
        let instruction = instruction.retainingStopFence(instruction.stopFence ?? AgentRunStartStopFence(session: session))
        await enqueue(owner: owner, session: session) { [self] in
            await performFollowUp(session: session, instruction: instruction, launch: launch)
        }.value
    }

    private func performFollowUp(
        session: AgentTabSession,
        instruction: AgentTabSession.PendingInstruction,
        launch: Launch?
    ) async {
        guard let owner = scope else { return }
        defer { withExtendedLifetime(owner) {} }
        guard owner.sessions[session.tabID] === session, !owner.hasReleasedWriterClaims else {
            if session.scheduledACPFollowUp == nil { session.mcpFollowUpRunPending = false }
            #if DEBUG
                session.perfRecorder.increment("run.followUp.dropped.staleSession", tabID: session.tabID)
                session.perfRecorder.event("run.followUp.dropped", tabID: session.tabID, fields: ["reason": "staleSession"])
            #endif
            owner.mcp.handleObservedMCPStateChange(for: session)
            return
        }
        let fence = instruction.stopFence ?? AgentRunStartStopFence(session: session)
        let outcome = AgentRunStartOutcomeRecorder()
        let admitted = !owner.isRetiring && fence.permitsStart(of: session) && launch != nil
        if admitted {
            await launch?.start(session, instruction.retainingStopFence(fence), outcome)
        }
        if !admitted, owner.sessions[session.tabID] === session,
           session.scheduledACPFollowUp == nil,
           fence.binding == session.persistentSessionBindingIdentity
        {
            session.mcpFollowUpRunPending = false
            owner.mcp.handleObservedMCPStateChange(for: session)
        }
        if !outcome.outcome.didStart,
           owner.sessions[session.tabID] === session, fence.permitsStart(of: session),
           session.selectedAgent.usesClaudeNativeRuntime,
           session.activeRunOwnership.map({ session.claudeTerminalAnchor?.0 == $0 }) == true
        {
            session.pendingInstructions.insert(instruction.retainingStopFence(fence), at: 0)
            session.isDirty = true
            owner.presentation.bindingChanged(session)
            owner.persistence.scheduleSave(for: session)
        }
    }

    private func restore(_ draft: String, session: AgentTabSession, owner: AgentSessionRuntimeStore.Scope, reason: String) {
        owner.drafts.restore(
            tabID: session.tabID, text: draft,
            message: "Restored local ACP follow-up after \(reason)", strategy: .prependAlways
        )
    }
}
