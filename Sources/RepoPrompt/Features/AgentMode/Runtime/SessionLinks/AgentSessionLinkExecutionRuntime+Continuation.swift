import Foundation
import MCP
import RepoPromptDomainRuntime

/// One transient wait, including its originating writer and run. Read projections on the payload
/// are not mutation authority; response and timeout paths must claim this exact record.
@MainActor
final class AgentInstructionWait {
    let id: UUID
    let writer: AgentSessionRuntimeStore.WriterIdentity
    let runOwnership: AgentRunOwnership?
    let runID: UUID?
    let runAttemptID: UUID?
    let continuation: CheckedContinuation<UserInstructionResponse, Error>
    var timeoutTask: Task<Void, Never>?
    var timeoutClaimed = false

    init(id: UUID, command: AgentSessionRuntimeStore.Command, continuation: CheckedContinuation<UserInstructionResponse, Error>) {
        self.id = id
        writer = command.identity
        let session = command.writer.session
        runOwnership = session.activeRunOwnership
        runID = session.runID
        runAttemptID = session.activeRunAttemptID
        self.continuation = continuation
    }

    func matchesRun(_ session: AgentTabSession) -> Bool {
        session.persistentSessionBindingIdentity == writer.restoration.bindingIdentity
            && session.activeRunOwnership == runOwnership && session.runID == runID
            && session.activeRunAttemptID == runAttemptID
    }
}

extension AgentSessionLinkExecutionRuntime {
    func instructionCommand(for session: AgentTabSession) -> AgentSessionRuntimeStore.Command? {
        try? scope?.admit(session: session)
    }

    func ownsInstructionWait(command: AgentSessionRuntimeStore.Command, waitID: UUID) -> Bool {
        let session = command.writer.session
        return command.writer.scope === scope && command.isCurrent
            && session.instructionWait?.id == waitID && session.instructionWait?.writer == command.identity
            && session.instructionWait?.matchesRun(session) == true
    }

    func replacePriorInstructionWait(command: AgentSessionRuntimeStore.Command) throws {
        guard command.writer.scope === scope, command.isCurrent else {
            throw MCPError.invalidParams("The Agent session changed while preparing to wait.")
        }
        AgentSessionInteractionRuntime.cancelPendingInstruction(for: command.writer.session)
    }

    func waitForInstruction(
        command: AgentSessionRuntimeStore.Command, waitID: UUID, prompt: String?, timeoutSeconds: TimeInterval?
    ) async throws -> UserInstructionResponse {
        guard command.writer.scope === scope, command.isCurrent else {
            throw MCPError.invalidParams("The Agent session changed while preparing to wait.")
        }
        let owner = command.writer.scope
        let session = command.writer.session
        defer { withExtendedLifetime(owner) {} }
        return try await withCheckedThrowingContinuation { continuation in
            guard command.isCurrent, session.instructionWait == nil else {
                continuation.resume(throwing: MCPError.invalidParams("The instruction wait changed before installation."))
                return
            }
            let wait = AgentInstructionWait(id: waitID, command: command, continuation: continuation)
            session.instructionWait = wait
            session.waitingPrompt = prompt
            session.clearClaudeReasoningStatus(clearDisplayedStatus: true)
            session.setRunningStatus(nil, source: nil)
            session.runState = .waitingForUser
            let message = (prompt?.isEmpty == false) ? prompt! : "What would you like me to do next?"
            session.appendItem(.assistantInline(message, sequenceIndex: session.nextSequenceIndex))
            if let timeout = timeoutSeconds {
                wait.timeoutTask = Task { @MainActor [weak self, weak session] in
                    do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                    catch { return }
                    guard let self, let session else { return }
                    await expireInstructionWait(session: session, waitID: waitID, timeout: timeout)
                }
            }
            // The continuation and timeout belong to the wait before any observer sees it.
            updateBindingsFromSession(session)
        }
    }

    /// The run service claims the original wait inside its cancellation entry, not before an
    /// await. Nil run ownership is an exact captured value here, never an active-Stop bypass.
    func expireInstructionWait(session: AgentTabSession, waitID: UUID, timeout: TimeInterval) async {
        guard let wait = session.instructionWait, wait.id == waitID else { return }
        guard wait.matchesRun(session), let owner = scope,
              owner.originatingWriter(identity: wait.writer, session: session) != nil,
              let execution = owner.execution
        else {
            settleExpiredInstructionWait(session: session, wait: wait, timeout: timeout)
            return
        }
        // Preserve the existing policy: another interaction can leave this wait consumable
        // without a timeout. Do not turn its timeout into a Stop of that interaction.
        guard session.runState == .waitingForUser else { return }
        let admission = AgentRunCancellationAdmission(
            scope: .instructionWaitTimeout, session: session,
            binding: wait.writer.restoration.bindingIdentity,
            expectedOwnership: wait.runOwnership, expectedRunID: wait.runID,
            cancellationGeneration: session.stopState.cancellationGeneration, pendingStartFence: nil,
            validateAndClaim: { [self, owner] in
                guard session.instructionWait === wait, wait.matchesRun(session),
                      owner.originatingWriter(identity: wait.writer, session: session) != nil else { return false }
                owner.installedInteractions?.cancelPendingQuestion(for: session)
                // The observer above is synchronous and may invalidate this exact owner.
                guard session.instructionWait === wait, wait.matchesRun(session),
                      owner.originatingWriter(identity: wait.writer, session: session) != nil else { return false }
                session.instructionWait = nil
                session.waitingPrompt = nil
                wait.timeoutClaimed = true
                // Do not cancel the timer task which is now joining terminal publication.
                wait.timeoutTask = nil
                withExtendedLifetime(self) {}
                return true
            }
        )
        await execution.cancelRun(
            tabID: session.tabID, session: session, intent: .userStop,
            completion: .terminalPublished, admission: admission
        )
        if wait.timeoutClaimed {
            // No payload access after joining: only the captured original continuation settles.
            wait.continuation.resume(returning: .init(text: nil, timedOut: true, elapsedSeconds: Int(timeout)))
        } else {
            // A rejected entry can only settle its original still-installed wait, never retry Stop.
            settleExpiredInstructionWait(session: session, wait: wait, timeout: timeout)
        }
    }

    private func settleExpiredInstructionWait(session: AgentTabSession, wait: AgentInstructionWait, timeout: TimeInterval) {
        guard session.instructionWait === wait else { return }
        session.instructionWait = nil
        wait.timeoutTask = nil
        if wait.matchesRun(session) {
            session.waitingPrompt = nil
            if !session.terminalCommitInProgress {
                AgentSessionInteractionRuntime.reconcileInteractiveRunState(session)
            }
        }
        if let scope, scope.originatingWriter(identity: wait.writer, session: session) != nil, wait.matchesRun(session) {
            updateBindingsFromSession(session)
        } else if scope?.sessions[session.tabID] === session {
            scope?.presentation.interactionChanged(session)
        }
        wait.continuation.resume(returning: .init(text: nil, timedOut: true, elapsedSeconds: Int(timeout)))
    }

    #if DEBUG
        func test_installInstructionWait(
            command: AgentSessionRuntimeStore.Command, waitID: UUID = UUID(),
            continuation: CheckedContinuation<UserInstructionResponse, Error>
        ) {
            precondition(command.writer.scope === scope && command.isCurrent)
            precondition(command.writer.session.instructionWait == nil)
            command.writer.session.instructionWait = AgentInstructionWait(id: waitID, command: command, continuation: continuation)
        }
    #endif

    /// Exact local object ownership, independently of any attached presentation. This does not
    /// prove link consent, canonical placement, provider routing or permission to start a turn.
    func ownsSession(_ session: AgentTabSession) -> Bool {
        guard let scope, !scope.hasReleasedWriterClaims else { return false }
        return scope.sessions[session.tabID] === session
    }

    /// Resume the existing instruction owner, then acknowledge only the input physically handed
    /// to that continuation. User and lane-update accounting remain separate; an automatic wake
    /// is never charged as user input or materialized as a user row.
    @discardableResult
    func resumeWaitingInstructionContinuation(
        command: AgentSessionRuntimeStore.Command,
        waitID: UUID,
        providerText: String,
        claim: AgentSessionLinkOutboundPromptClaim?,
        origin: UserInstructionResponse.Origin,
        inputProof: AgentSessionLinkProviderInputRelease.Proof? = nil,
        undecoratedProviderText: String? = nil
    ) -> Bool {
        let session = command.writer.session
        guard let owner = scope, !owner.isRetiring, commands.isAvailable(),
              ownsInstructionWait(command: command, waitID: waitID),
              let wait = session.instructionWait else { return false }
        defer { withExtendedLifetime(owner) {} }
        session.noteAcceptedTaskInput() // User and lane-update continuations reuse, never reset, the attempt.
        let released = inputProof.flatMap { proof in
            claim.map { agentSessionLinkHandoffProviderInput(for: session, dispatchID: $0.dispatchID, claim: $0, proof: proof) }
        }
        guard released?.mustAbortDispatch != true else { return false }
        let providerText = released.flatMap { release in undecoratedProviderText.map(release.text) } ?? providerText
        let claim = released == nil ? claim : released?.claim
        switch origin {
        case .user:
            owner.usage.addUserInputTokensToActiveNonCodexTurn(
                AgentSessionUsageRuntime.estimateRuntimeTokens(for: providerText),
                for: session
            )
        case .laneUpdateAutoWake:
            owner.usage.addToolInputTokens(providerText, for: session)
        }
        wait.timeoutTask?.cancel()
        wait.timeoutTask = nil
        session.instructionWait = nil
        session.waitingPrompt = nil
        session.runState = .running
        wait.continuation.resume(returning: UserInstructionResponse(
            text: providerText,
            timedOut: false,
            elapsedSeconds: 0,
            origin: origin
        ))
        // Successful resume(returning:) remains the physical acceptance boundary.
        acceptAgentSessionLinkPromptClaim(claim)
        // Optional presentation can reenter or detach its legacy command owner. Publish only
        // after the physical delivery and its receipt are settled in this actor turn.
        updateBindingsFromSession(session)
        return true
    }
}
