import Foundation
import RepoPromptDomainRuntime

/// One-shot, exact-object managed Stop. The authority fence precedes every target mutation;
/// cancellation then follows the same run-service path as the lane user's Stop.
extension AgentSessionLinkExecutionRuntime {
    func agentSessionLinkPerformStop(
        to candidate: AgentSessionLinkEndpointCandidate,
        request: AgentSessionLinkStopRequest,
        liveness: @escaping AgentSessionLinkSendLivenessProbe,
        queueHasCommittedDrain: @escaping @MainActor () -> Bool,
        withdrawInbound: @escaping @MainActor () -> Bool,
        commitAuthorization: @MainActor () async -> AgentSessionLinkSendCommitOutcome,
        teardownDeadlineSeconds: TimeInterval = 30,
        auditDeadlineSeconds: TimeInterval = 5,
        deadlineSleep: @escaping @MainActor (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        beforeCleanupTask: @escaping @MainActor () -> Void = {}
    ) async -> AgentSessionLinkStopTransactionOutcome {
        guard let command = admit(candidate), liveness().permitsDelivery else {
            return .blocked(.endpointInvalidated)
        }
        defer { withExtendedLifetime(command) {} }
        let writer = command.writer
        let session = writer.session
        guard let interactions = writer.scope.installedInteractions,
              writer.scope.execution != nil,
              writer.scope.mcp.settledSession(for: writer) === session
        else {
            return .blocked(.targetLoading)
        }
        let initial = Self.agentSessionLinkDeliveryReadinessSnapshot(
            session: session, endpointMatchesGrant: true, isClosing: false
        )
        if case let .blocked(failure) = AgentSessionLinkStopAdmission.classify(initial) {
            return .blocked(failure)
        }
        if queueHasCommittedDrain() { return .blocked(.targetBusy) }

        let commit = await commitAuthorization()
        guard commit == .committed else { return .blocked(commit.refusal) }

        // No suspension from this recheck through selection, queue withdrawal and gate claim.
        guard command.isCurrent,
              agentSessionLinkObserverEndpoint(tabID: candidate.tabID) == candidate.domainEndpoint,
              liveness().permitsDelivery,
              writer.scope.mcp.settledSession(for: writer) === session
        else { return .blocked(.endpointInvalidated) }
        let snapshot = Self.agentSessionLinkDeliveryReadinessSnapshot(
            session: session, endpointMatchesGrant: true, isClosing: false
        )
        let selection = AgentSessionLinkStopAdmission.classify(snapshot)
        if case let .blocked(failure) = selection { return .blocked(failure) }
        if queueHasCommittedDrain() { return .blocked(.targetBusy) }
        guard let binding = session.persistentSessionBindingIdentity else { return .blocked(.targetBusy) }
        let oracleHadWork = session.oracleBackgroundOwner.map { OracleBackgroundInvocationRegistry.shared.hasLiveOwner($0) } ?? false
        var oracleDrained = !oracleHadWork

        if selection == .notRunning {
            interactions.prepareRunCancellation(session: session, intent: .userStop, origin: .explicitStop, links: self)
            oracleDrained = await interactions.awaitOracleBackgroundDrain(for: session, timeout: teardownDeadlineSeconds)
            return .settled(Self.agentSessionLinkStopReceipt(
                request: request, targetSessionID: candidate.sessionID,
                result: oracleHadWork ? (oracleDrained ? .stopped : .stopFailed) : .notRunning,
                failure: oracleDrained ? nil : .cancellationUnconfirmed,
                stopRequested: oracleHadWork, teardownCompleted: oracleHadWork ? oracleDrained : nil, audit: .notRequired,
                runState: session.persistentSessionBindingIdentity == binding ? session.runState.rawValue : nil
            ))
        }
        if selection == .activeRun, session.activeRunOwnership == nil || session.runID == nil {
            return .blocked(.targetBusy)
        }
        guard withdrawInbound() else { return .blocked(.targetBusy) }

        let pendingComposerStart = selection == .pendingStart ? session.composerStartCancellation : nil
        let admission = AgentRunCancellationAdmission(
            scope: selection == .activeRun ? .activeRun : .pendingStart,
            session: session,
            binding: binding,
            expectedOwnership: session.activeRunOwnership,
            expectedRunID: session.runID,
            cancellationGeneration: session.stopState.cancellationGeneration,
            pendingStartFence: nil,
            expectedComposerAttemptID: pendingComposerStart?.attemptID,
            validateAndClaim: { writer.isCurrent }
        )

        if selection == .pendingStart {
            guard withdrawPendingStartForSessionLink(session: session, admission: admission) else {
                return .settled(Self.agentSessionLinkStopReceipt(
                    request: request, targetSessionID: candidate.sessionID,
                    result: .stopFailed, failure: .cancellationUnconfirmed,
                    stopRequested: true, audit: .notRequired
                ))
            }
            let itemID = agentSessionLinkAppendStopRow(
                request: request, candidate: candidate, session: session, binding: binding, writer: writer
            )
            let composerDrained = await awaitPendingComposerStartDrain(
                pendingComposerStart, command: command, requestID: request.requestID,
                deadlineSeconds: teardownDeadlineSeconds, deadlineSleep: deadlineSleep
            )
            let oracleDrained = await interactions.awaitOracleBackgroundDrain(for: session, timeout: teardownDeadlineSeconds)
            guard composerDrained, oracleDrained else {
                return .settled(Self.agentSessionLinkStopReceipt(
                    request: request,
                    targetSessionID: candidate.sessionID,
                    result: .stopFailed,
                    failure: .cancellationUnconfirmed,
                    stopRequested: true,
                    teardownCompleted: false,
                    itemID: itemID,
                    audit: itemID == nil ? .notRequired : .unknown
                ))
            }
            let audit = await agentSessionLinkFlushStopAudit(
                candidate: candidate, session: session, binding: binding, writer: writer,
                itemID: itemID, deadlineSeconds: auditDeadlineSeconds,
                deadlineSleep: deadlineSleep
            )
            return .settled(Self.agentSessionLinkStopReceipt(
                request: request, targetSessionID: candidate.sessionID,
                result: .stopped, stopRequested: true, teardownCompleted: true, itemID: itemID,
                audit: audit, runState: "pending_start_withdrawn"
            ))
        }

        guard let ownership = session.activeRunOwnership, session.runID != nil else {
            return .blocked(.targetBusy)
        }
        // This is the synchronous claim: a deferred producer cannot enter while the cleanup task
        // is waiting for its first MainActor turn.
        guard session.stopState.claimManagedStop(id: request.requestID, binding: binding) else {
            return .blocked(.targetBusy)
        }
        // Claim-time withdrawal is independent of whether the run still exists when cleanup starts.
        interactions.prepareRunCancellation(session: session, intent: .userStop, origin: .explicitStop, links: self)
        withdrawQueuedWorkForManagedStop(session: session)
        let oracleDrain = session.oracleBackgroundDrain
        let claimedAdmission = AgentRunCancellationAdmission(
            scope: .activeRun, session: session, binding: binding,
            expectedOwnership: admission.expectedOwnership, expectedRunID: admission.expectedRunID,
            cancellationGeneration: session.stopState.cancellationGeneration,
            pendingStartFence: nil, validateAndClaim: admission.validateAndClaim
        )
        session.noteMonitorObservationInputsChanged()
        requestUIRefresh(tabID: candidate.tabID, urgent: true)
        let recorder = AgentRunCancellationOutcomeRecorder(
            expectedOwnership: ownership,
            expectedRunID: session.runID,
            expectedBinding: binding,
            onAcceptedPrimaryPublication: { [weak self] _ in
                guard let self else { return }
                _ = agentSessionLinkAppendStopRow(
                    request: request, candidate: candidate, session: session, binding: binding, writer: writer
                )
            }
        )
        let teardown = AgentSessionLinkStopSignal<Bool>()
        let audit = AgentSessionLinkStopSignal<DomainAgentSessionLinkStopReceipt.AuditStatus>()
        let cleanup = Task { [weak self, command] in
            session.stopState.markCleanupStarted(id: request.requestID, binding: binding)
            guard let self else {
                _ = session.stopState.releaseManagedStop(id: request.requestID, binding: binding)
                session.noteMonitorObservationInputsChanged()
                teardown.finish(false)
                audit.finish(.unknown)
                return
            }
            defer {
                pendingStopEffects.removeValue(forKey: request.requestID)
                command.writer.scope.noteSettlementChanged()
                withExtendedLifetime(command) {}
            }
            beforeCleanupTask()
            let routed = await cancelAgentRunForSessionLink(
                session: session, admission: claimedAdmission, outcomeRecorder: recorder
            )
            if let oracleDrain {
                oracleDrained = await OracleBackgroundInvocationRegistry.awaitDrain(oracleDrain, timeout: teardownDeadlineSeconds)
            }
            teardown.finish(routed && recorder.teardownCompleted && oracleDrained)
            if session.stopState.releaseManagedStop(id: request.requestID, binding: binding) {
                session.noteMonitorObservationInputsChanged()
                requestUIRefresh(tabID: candidate.tabID, urgent: true)
            }
            let itemID = session.items.contains(where: { $0.id == request.requestID })
                ? request.requestID : nil
            await audit.finish(agentSessionLinkFlushStopAudit(
                candidate: candidate, session: session, binding: binding, writer: writer,
                itemID: itemID, deadlineSeconds: auditDeadlineSeconds,
                deadlineSleep: deadlineSleep
            ))
        }
        pendingStopEffects[request.requestID] = PendingSendEffect(sessionIdentity: ObjectIdentifier(session), task: cleanup)
        Task {
            await deadlineSleep(teardownDeadlineSeconds)
            teardown.finish(false)
            session.stopState.markCleanupUnclaimedIfNeverStarted(id: request.requestID, binding: binding)
        }
        let teardownCompleted = await teardown.value()
        /// A terminal state on this mutable session is not evidence that the captured run ended:
        /// the same object can be rebound or repurposed for a replacement attempt while cleanup waits.
        func matchedTerminalRunState() -> String? {
            guard session.persistentSessionBindingIdentity == binding,
                  session.runState.isTerminalForCommit else { return nil }
            if let revision = session.lastTerminalCommitRevision {
                guard revision.ownership == ownership,
                      revision.expectedRunID == admission.expectedRunID else { return nil }
                return revision.terminalState.rawValue
            }
            guard session.activeRunOwnership == ownership,
                  session.runID == admission.expectedRunID else { return nil }
            return session.runState.rawValue
        }
        let accepted = if case .accepted? = recorder.publicationResult { true } else { false }
        let itemID = session.items.contains(where: { $0.id == request.requestID })
            ? request.requestID : nil
        @MainActor func settledTerminalWithoutPublication(requireOracleDrain: Bool) -> AgentSessionLinkStopTransactionOutcome? {
            if recorder.initiatedCancellation, recorder.teardownCompleted, !requireOracleDrain || oracleDrained,
               recorder.publicationResult == nil, let terminalState = matchedTerminalRunState()
            {
                return .settled(Self.agentSessionLinkStopReceipt(
                    request: request, targetSessionID: candidate.sessionID,
                    result: .notRunning, stopRequested: true,
                    teardownCompleted: true, audit: .notRequired,
                    runState: terminalState
                ))
            }
            return nil
        }
        @MainActor func settledStop(auditStatus: DomainAgentSessionLinkStopReceipt.AuditStatus) -> AgentSessionLinkStopTransactionOutcome {
            let failure: DomainAgentSessionLinkStopReceipt.FailureReason? = switch recorder.publicationResult {
            case .accepted?: nil
            case .stale?: .terminalPublicationStale
            case .rejected?: .terminalPublicationRejected
            case nil: recorder.initiatedCancellation ? .cancellationUnconfirmed : .targetChanged
            }
            return .settled(Self.agentSessionLinkStopReceipt(
                request: request, targetSessionID: candidate.sessionID,
                result: accepted ? .stopped : .stopFailed,
                failure: failure,
                stopRequested: recorder.initiatedCancellation,
                teardownCompleted: recorder.teardownCompleted,
                itemID: itemID, audit: auditStatus,
                runState: recorder.primaryRevision?.terminalState.rawValue
            ))
        }
        if !recorder.initiatedCancellation, oracleHadWork {
            return .settled(Self.agentSessionLinkStopReceipt(
                request: request,
                targetSessionID: candidate.sessionID,
                result: oracleDrained ? .stopped : .stopFailed,
                failure: oracleDrained ? nil : .cancellationUnconfirmed,
                stopRequested: true,
                teardownCompleted: oracleDrained,
                audit: .notRequired,
                runState: matchedTerminalRunState()
            ))
        }
        if !teardownCompleted {
            if !recorder.initiatedCancellation, let terminalState = matchedTerminalRunState() {
                return .settled(Self.agentSessionLinkStopReceipt(
                    request: request, targetSessionID: candidate.sessionID,
                    result: .notRunning, stopRequested: false,
                    audit: .notRequired, runState: terminalState
                ))
            }
            if let settled = settledTerminalWithoutPublication(requireOracleDrain: true) { return settled }
            // Publication and local teardown remain independent receipts.
            return settledStop(auditStatus: itemID == nil ? .notRequired : .unknown)
        }
        Task {
            await deadlineSleep(auditDeadlineSeconds)
            audit.finish(.unknown)
        }
        let auditStatus = await audit.value()
        if let settled = settledTerminalWithoutPublication(requireOracleDrain: false) { return settled }
        return settledStop(auditStatus: auditStatus)
    }

    private func agentSessionLinkAppendStopRow(
        request: AgentSessionLinkStopRequest,
        candidate: AgentSessionLinkEndpointCandidate,
        session: TabSession,
        binding: AgentPersistentSessionBindingIdentity,
        writer: AgentSessionRuntimeStore.Writer
    ) -> UUID? {
        guard writer.isCurrent, writer.session === session,
              session.persistentSessionBindingIdentity == binding
        else { return nil }
        if session.items.contains(where: { $0.id == request.requestID }) { return request.requestID }
        session.appendItem(.overseerRunStopped(
            stopID: request.requestID, stoppedAt: Date(),
            attribution: request.attribution, sequenceIndex: session.nextSequenceIndex
        ))
        updateBindingsFromSession(session)
        scheduleSave(for: candidate.tabID)
        requestUIRefresh(tabID: candidate.tabID, urgent: true)
        return request.requestID
    }

    private func agentSessionLinkFlushStopAudit(
        candidate: AgentSessionLinkEndpointCandidate,
        session: TabSession,
        binding: AgentPersistentSessionBindingIdentity,
        writer: AgentSessionRuntimeStore.Writer,
        itemID: UUID?,
        deadlineSeconds: TimeInterval,
        deadlineSleep: @escaping @MainActor (TimeInterval) async -> Void
    ) async -> DomainAgentSessionLinkStopReceipt.AuditStatus {
        guard let itemID else { return .failed }
        guard writer.isCurrent, writer.session === session,
              session.persistentSessionBindingIdentity == binding
        else { return .failed }
        let signal = AgentSessionLinkStopSignal<DomainAgentSessionLinkStopReceipt.AuditStatus>()
        let effectID = UUID()
        let flush = Task { [weak self, writer] in
            guard let self else { signal.finish(.unknown)
                return
            }
            defer {
                pendingStopEffects.removeValue(forKey: effectID)
                writer.scope.noteSettlementChanged()
                withExtendedLifetime(writer) {}
            }
            guard writer.isCurrent, writer.session === session,
                  session.persistentSessionBindingIdentity == binding,
                  session.items.contains(where: { $0.id == itemID })
            else { signal.finish(.failed)
                return
            }
            let result = await writer.scope.persistence.flushSaveRequired(
                writer: writer
            )
            guard writer.isCurrent, writer.session === session,
                  session.persistentSessionBindingIdentity == binding,
                  session.items.contains(where: { $0.id == itemID })
            else { signal.finish(.failed)
                return
            }
            switch result {
            case .success: signal.finish(.persisted)
            case .failure: signal.finish(.failed)
            }
        }
        pendingStopEffects[effectID] = PendingSendEffect(sessionIdentity: ObjectIdentifier(session), task: flush)
        Task {
            await deadlineSleep(deadlineSeconds)
            signal.finish(.unknown)
        }
        return await signal.value()
    }

    /// Teardown joins these effects separately from terminal publication: a Stop cleanup itself
    /// waits for terminal publication, so the terminal hook must never join this collection.
    /// An exact-session join excludes sibling effects but still waits for the real cleanup and
    /// audit producers after waiter cancellation. Completion alone is not a save acknowledgment.
    func drainPendingStopEffects(for session: AgentTabSession? = nil) async {
        let identity = session.map(ObjectIdentifier.init)
        while true {
            let pending = pendingStopEffects.values.filter { identity == nil || $0.sessionIdentity == identity }
            guard !pending.isEmpty else { return }
            for effect in pending {
                await effect.task.value
            }
        }
    }

    /// Uses the scope's same execution service as provider start, with the caller's exact
    /// cancellation admission. It never looks up another window or chooses a replacement object.
    @discardableResult
    func cancelAgentRunForSessionLink(
        session: TabSession,
        admission: AgentRunCancellationAdmission,
        outcomeRecorder: AgentRunCancellationOutcomeRecorder,
        completion: AgentModeRunService.CancellationCompletion = .terminalTeardownCompleted
    ) async -> Bool {
        guard let scope, let sessionID = session.activeAgentSessionID,
              case let .unique(writer) = scope.resolveWriter(sessionID: sessionID),
              writer.scope === scope, writer.session === session,
              let execution = scope.execution else { return false }
        defer { withExtendedLifetime(writer) {} }
        await execution.cancelRun(
            tabID: session.tabID, session: session, intent: .userStop,
            completion: completion, origin: .explicitStop,
            admission: admission, outcomeRecorder: outcomeRecorder
        )
        return outcomeRecorder.initiatedCancellation
    }

    private func awaitPendingComposerStartDrain(
        _ start: AgentComposerStartCancellation?, command: AgentSessionRuntimeStore.Command,
        requestID: UUID, deadlineSeconds: TimeInterval,
        deadlineSleep: @escaping @MainActor (TimeInterval) async -> Void
    ) async -> Bool {
        guard let start, !start.isFinalized else { return true }
        let result = AgentSessionLinkStopSignal<Bool>()
        let cleanup = Task { [self, command] in
            await start.finalized.value()
            pendingStopEffects.removeValue(forKey: requestID)
            command.writer.scope.noteSettlementChanged()
            result.finish(true)
            withExtendedLifetime(command) {}
        }
        pendingStopEffects[requestID] = PendingSendEffect(sessionIdentity: ObjectIdentifier(command.writer.session), task: cleanup)
        Task { await deadlineSleep(deadlineSeconds)
            result.finish(false)
        }
        return await result.value()
    }

    @discardableResult
    func withdrawPendingStartForSessionLink(session: TabSession, admission: AgentRunCancellationAdmission) -> Bool {
        guard let scope, let sessionID = session.activeAgentSessionID,
              case let .unique(writer) = scope.resolveWriter(sessionID: sessionID),
              writer.scope === scope, writer.session === session,
              let execution = scope.execution else { return false }
        let withdrawn = execution.withdrawPendingStartForSessionLink(tabID: session.tabID, session: session, admission: admission)
        if withdrawn {
            updateBindingsFromSession(session)
            scheduleSave(for: session)
            requestUIRefresh(tabID: session.tabID, urgent: true)
        }
        return withdrawn
    }

    func withdrawQueuedWorkForManagedStop(session: TabSession) {
        guard let scope, scope.sessions[session.tabID] === session else { return }
        scope.installedInteractions?.closeOracleBackground(for: session)
        scope.execution?.withdrawQueuedWorkForManagedStop(tabID: session.tabID, session: session)
        updateBindingsFromSession(session)
        scheduleSave(for: session)
    }

    private static func agentSessionLinkStopReceipt(
        request: AgentSessionLinkStopRequest,
        targetSessionID: UUID,
        result: DomainAgentSessionLinkStopReceipt.Result,
        failure: DomainAgentSessionLinkStopReceipt.FailureReason? = nil,
        stopRequested: Bool?,
        teardownCompleted: Bool? = nil,
        itemID: UUID? = nil,
        audit: DomainAgentSessionLinkStopReceipt.AuditStatus,
        runState: String? = nil
    ) -> DomainAgentSessionLinkStopReceipt {
        DomainAgentSessionLinkStopReceipt(
            requestID: request.requestID, targetSessionID: targetSessionID,
            result: result, failureReason: failure,
            stopRequested: stopRequested, teardownCompleted: teardownCompleted,
            targetItemID: itemID?.uuidString, auditStatus: audit,
            resultingRunState: runState, settledAt: Date()
        )
    }
}
