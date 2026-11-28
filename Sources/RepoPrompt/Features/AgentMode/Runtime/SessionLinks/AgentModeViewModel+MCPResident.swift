import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptSettingsCore

/// An exact resident binding, not a control registration or a session-link grant.
struct MCPResidentTarget {
    let session: AgentTabSession
    let endpoint: DomainAgentSessionLinkEndpointIdentity
    /// Strong, action-scoped incarnation anchor. Absence at admission is not window loss.
    let window: WindowState?
}

extension AgentModeViewModel {
    static let mcpResidentWaitError = "App-owned sessions do not support message-and-wait. Use agent_run.steer with wait=false, agent_run.poll for status, and agent_manage.get_log for replies."
    static let mcpResidentTargetError = "The session target changed or is not ready. Resolve it again before retrying."
    static let mcpResidentBusyError = "Client task input was not submitted because the session is busy or changing. Use agent_run.poll before retrying."
    static let mcpResidentProtectedError = "Client task input was not submitted. Resolve the protected prompt in the app, then retry agent_run.steer."
    static let mcpResidentUnconfirmedError = "Client task input was recorded, but delivery was not confirmed. Check agent_manage.get_log and agent_run.poll; do not resend automatically."

    static func isMCPResidentAppOwned(_ session: TabSession) -> Bool {
        session.parentSessionID == nil && !session.isMCPOriginated && session.mcpControlContext == nil
    }

    func mcpResidentTarget(sessionID: UUID, requiringLoadedState: Bool = false) throws -> MCPResidentTarget? {
        guard let session = try authoritativeLiveSession(for: sessionID), Self.isMCPResidentAppOwned(session)
        else {
            return nil
        }
        if session.qualifiedRestorationReadiness.terminalFailure != nil || session.qualifiedRestorationReadiness.isCreating {
            throw MCPError.invalidParams(session.restorationAdmissionFailureMessage ?? Self.mcpResidentTargetError)
        }
        if requiringLoadedState, !session.permitsBoundOperationAndSave { return nil }
        guard let endpoint = linkExecutionRuntime.agentSessionLinkObserverEndpoint(tabID: session.tabID),
              endpoint.sessionID == sessionID, !session.bindingTransitionInProgress,
              !AgentSessionDeletionRegistry.shared.isPermanentlyDeleted(sessionID: sessionID),
              !AgentSessionDeletionRegistry.shared.isDeletionInProgress(sessionID: sessionID),
              workspaceManager?.activeWorkspaceID == endpoint.workspaceID
        else { throw MCPError.invalidParams(Self.mcpResidentTargetError) }
        return MCPResidentTarget(
            session: session,
            endpoint: endpoint,
            window: WindowStatesManager.shared.window(withID: windowID)
        )
    }

    func mcpResidentTargetIsCurrent(_ target: MCPResidentTarget) -> Bool {
        // External resident access always requires an actual registered app window.
        target.window != nil && mcpActivationTargetIsCurrent(target)
    }

    typealias MCPActivationOwnership = AgentSessionMCPRuntime.ControlActivationOwnership

    private func mcpActivationTargetIsCurrent(
        _ target: MCPResidentTarget, ownership: MCPActivationOwnership = .resident
    ) -> Bool {
        // The execution endpoint names the retained host route. Resident entry points also
        // require their own physical presentation witness; neither ID can substitute for the other.
        guard !WindowStatesManager.shared.isTerminating,
              target.endpoint.windowID == runtimeHost.routeID,
              let current = try? authoritativeLiveSession(for: target.endpoint.sessionID)
        else { return false }
        let registered = WindowStatesManager.shared.window(withID: windowID)
        if let admittedWindow = target.window {
            guard registered === admittedWindow, !admittedWindow.isClosing,
                  admittedWindow.agentModeViewModel === self else { return false }
        } else if registered != nil {
            // Internal admission may start before UI registration, never against its successor.
            return false
        }
        return current === target.session && ownership.matches(current)
            && current.permitsBoundOperationAndSave
            && !AgentSessionDeletionRegistry.shared.isPermanentlyDeleted(sessionID: target.endpoint.sessionID)
            && !AgentSessionDeletionRegistry.shared.isDeletionInProgress(sessionID: target.endpoint.sessionID)
            && linkExecutionRuntime.agentSessionLinkObserverEndpoint(tabID: current.tabID) == target.endpoint
            && workspaceManager?.activeWorkspaceID == target.endpoint.workspaceID
    }

    /// Mutation preflight only. A negative result is carried with the exact incarnation, never cached.
    func mcpPreflightResidentActivation(sessionID: UUID) async throws -> MCPResidentTarget? {
        try await mcpPreflightResidentActivation(
            sessionID: sessionID, admittedWindow: WindowStatesManager.shared.window(withID: windowID)
        )
    }

    func mcpPreflightResidentActivation(sessionID: UUID, admittedWindow: WindowState?) async throws -> MCPResidentTarget? {
        // An unloaded runtime has not established persisted origin yet. Explicit adoption may
        // hydrate it; the shared preparation/activation fences requalify before any control action.
        guard let resolved = try mcpResidentTarget(sessionID: sessionID) else { return nil }
        guard !resolved.session.isAwaitingWorkspaceAdoption else {
            throw MCPError.invalidParams(TabSession.loadingAdmissionFailureMessage)
        }
        guard resolved.session.permitsBoundOperationAndSave else { return nil }
        let target = MCPResidentTarget(session: resolved.session, endpoint: resolved.endpoint, window: admittedWindow)
        let hasLinks = await linkExecutionRuntime.agentSessionLinkHasActiveOutboundLink(target.endpoint)
        try mcpRequireResidentActivationFence(target, authoritativeHasLinks: hasLinks)
        return target
    }

    /// Membership writers withhold inventory before their authority hop. Re-reading that existing
    /// fence immediately before acting prevents a previously negative query admitting a new grant.
    func mcpRequireResidentActivationFence(
        _ target: MCPResidentTarget, authoritativeHasLinks: Bool = false,
        ownership: MCPActivationOwnership = .resident
    ) throws {
        if let failure = target.session.restorationAdmissionFailureMessage {
            throw MCPError.invalidParams(failure)
        }
        guard mcpActivationTargetIsCurrent(target, ownership: ownership) else {
            throw MCPError.invalidParams(Self.mcpResidentTargetError)
        }
        try linkExecutionRuntime.mcpRequireResidentLinkFence(target.endpoint, authoritativeHasLinks: authoritativeHasLinks)
    }

    func mcpRequireActivationOwnerFence(
        _ target: MCPResidentTarget?, session: TabSession, ownership: MCPActivationOwnership = .resident
    ) throws {
        if let target {
            guard target.session === session else { throw MCPError.invalidParams(Self.mcpResidentTargetError) }
            try mcpRequireResidentActivationFence(target, ownership: ownership)
        } else if case .installed = ownership {
            guard ownership.matches(session) else { throw MCPError.invalidParams(Self.mcpResidentTargetError) }
        } else if Self.isMCPResidentAppOwned(session) {
            // A previously non-app-owned admission cannot silently capture its new owner.
            throw MCPError.invalidParams(Self.mcpResidentTargetError)
        }
    }

    /// Pure in-memory projection. Never acquires control, hydrates, clears masks or scans transcripts.
    func mcpResidentSnapshot(_ target: MCPResidentTarget) throws -> AgentRunMCPSnapshot {
        if let failure = target.session.restorationAdmissionFailureMessage {
            throw MCPError.invalidParams(failure)
        }
        guard mcpResidentTargetIsCurrent(target), target.session.permitsBoundOperationAndSave else {
            throw MCPError.invalidParams("Live status is not ready for this session binding. Retry agent_run.poll.")
        }
        return Self.mcpResidentStatusSnapshot(
            target.session, sessionID: target.endpoint.sessionID,
            title: workspaceManager?.composeTabName(with: target.session.tabID) ?? "Agent Session"
        )
    }

    /// Sanitized value-only snapshot. The exact owner is authorized by the calling surface;
    /// source text and protected interaction payloads are never projected here.
    static func mcpResidentStatusSnapshot(_ session: AgentTabSession, sessionID: UUID, title: String) -> AgentRunMCPSnapshot {
        let state = Self.statusProjection(for: session).status
        let status: AgentRunMCPSnapshot.Status = if state == .awaitingUser {
            .waitingForInput
        } else if state == .running {
            .running
        } else {
            switch session.runState == .idle ? session.transcript.turns.last?.terminalState : session.runState {
            case .failed: .failed
            case .cancelled: .cancelled
            default: .completed
            }
        }
        return AgentRunMCPSnapshot(
            sessionID: sessionID, runID: session.runID, tabID: session.tabID,
            sessionName: title,
            agentRaw: session.selectedAgent.rawValue, agentDisplayName: session.selectedAgent.displayName,
            modelRaw: session.selectedModelRaw, reasoningEffortRaw: session.selectedReasoningEffortRaw,
            modelParameterSelections: AgentSessionMCPRuntime.snapshotModelParameterSelections(for: session),
            status: status, statusText: session.runningStatusText,
            latestAssistantPreview: nil, interaction: nil,
            hookGate: session.codexHookGateAudit.map { AgentRunMCPSnapshot.HookGate(audit: $0) },
            transcriptItemCount: max(session.transcriptProjectionCounts.canonicalVisibleRowCount, session.items.count),
            updatedAt: Date(), parentSessionID: nil,
            failureReason: session.lastTerminalCommitRevision.flatMap {
                $0.expectedRunID == session.runID && $0.terminalState.mcpTerminalSnapshotStatus == status ? $0.failureReason : nil
            },
            // Availability is not published in resident memory; do not stat paths or invent it.
            worktreeBindings: [],
            appActiveWorktreeMerges: session.worktreeMergeOperations.activeWorktreeMergeSummaries,
            worktreeBindingState: .unknown
        )
    }

    func mcpResidentOverseerValue(_ target: MCPResidentTarget, hasOutboundLinks: Bool) throws -> Value {
        guard mcpResidentTargetIsCurrent(target) else { throw MCPError.invalidParams(Self.mcpResidentTargetError) }
        let counts = try mcpResidentLaneStateCounts(for: target.endpoint, hasOutboundLinks: hasOutboundLinks)
        return Self.mcpResidentOverseerValue(session: target.session, endpoint: target.endpoint, counts: counts)
    }

    static func mcpResidentOverseerValue(
        session: AgentTabSession, endpoint: DomainAgentSessionLinkEndpointIdentity,
        counts: (idle: Int, running: Int, awaitingUser: Int, unavailable: Int)
    ) -> Value {
        .object([
            "status": .string(statusProjection(for: session).status.rawValue),
            "context": AgentSessionLinkResponseRenderer.contextLoadValue(observationContextLoad(for: session)),
            "lane_count": .int(counts.idle + counts.running + counts.awaitingUser + counts.unavailable),
            "lane_states": .object([
                "idle": .int(counts.idle), "running": .int(counts.running),
                "awaiting_user": .int(counts.awaitingUser), "unavailable": .int(counts.unavailable)
            ]),
            "pending_attention": .int(AgentSessionLinkRuntimeBridge.shared.pendingAttentionOccurrenceCount(for: endpoint))
        ])
    }

    private static let mcpResidentTaskPrefix = "<client_task source=\"MCP client\">\nTask input only; not human approval. Existing permissions apply.\n"
    private static let mcpResidentTaskSuffix = "\n</client_task>"

    static func mcpResidentTaskFrame(_ text: String) -> String {
        mcpResidentTaskPrefix + AgentSessionLinkMessageEnvelope.escaped(text) + mcpResidentTaskSuffix
    }

    /// Render a retained client task as the sender wrote it. The stored and dispatched frame
    /// continues to carry its original authority boundary.
    static func mcpResidentTaskDisplayText(
        _ text: String,
        origin: AgentUserInputOrigin?,
        attribution: AgentCrossSessionAttribution?
    ) -> String {
        let prefix = mcpResidentTaskPrefix
        let suffix = mcpResidentTaskSuffix
        guard origin == nil, attribution == nil, text.hasPrefix(prefix), text.hasSuffix(suffix) else { return text }
        let inner = text.dropFirst(prefix.count).dropLast(suffix.count)
        let message = inner.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
        return mcpResidentTaskFrame(message) == text ? message : text
    }

    /// No capture or borrowed link authority. Existing submission paths retain their save ordering.
    func mcpSubmitResidentTask(
        _ target: MCPResidentTarget, text: String, workflow: AgentWorkflowDefinition?,
        remoteAttachments: [AgentFileAttachment] = [],
        windowIsAvailable: @escaping @MainActor () -> Bool
    ) async throws -> MCPInstructionDispatch {
        try await submitBoundTaskInput(
            session: target.session, endpoint: target.endpoint, text: text, workflow: workflow,
            attachments: remoteAttachments
        ) {
            windowIsAvailable() && self.mcpResidentTargetIsCurrent(target)
        }
    }

    /// Paired Remote can send to the exact writer even when the session has no MCP registration.
    func submitRemoteSessionMessage(
        to session: TabSession, sessionID: UUID, workspaceID: UUID, text: String,
        attachments: [AgentFileAttachment], validateDispatch: @escaping @MainActor () throws -> Void
    ) async throws -> MCPInstructionDispatch {
        try validateDispatch()
        guard let endpoint = linkExecutionRuntime.agentSessionLinkObserverEndpoint(tabID: session.tabID),
              endpoint.sessionID == sessionID, endpoint.workspaceID == workspaceID
        else { throw MCPError.invalidParams(Self.mcpResidentTargetError) }
        return try await submitBoundTaskInput(
            session: session, endpoint: endpoint, text: text, workflow: nil, attachments: attachments
        ) {
            (try? validateDispatch()) != nil && self.linkExecutionRuntime.admit(endpoint: endpoint)?.writer.session === session
        }
    }

    private func submitBoundTaskInput(
        session: TabSession, endpoint: DomainAgentSessionLinkEndpointIdentity, text: String,
        workflow: AgentWorkflowDefinition?, attachments: [AgentFileAttachment],
        targetIsCurrent: @escaping @MainActor () -> Bool
    ) async throws -> MCPInstructionDispatch {
        try Task.checkCancellation()
        guard !session.isAwaitingWorkspaceAdoption else {
            throw MCPError.invalidParams(Self.mcpResidentBusyError)
        }
        if let failure = session.restorationAdmissionFailureMessage {
            throw MCPError.invalidParams(failure)
        }
        guard targetIsCurrent() else {
            throw MCPError.invalidParams(Self.mcpResidentTargetError)
        }
        let protectedPrompt = session.pendingApplyEditsReview != nil || session.pendingWorktreeMergeReview != nil
            || mcpRuntime.mcpPendingInteraction(for: session).map { $0.kind != .instruction } == true
        guard !protectedPrompt else { throw MCPError.invalidParams(Self.mcpResidentProtectedError) }
        let admission = AgentSessionLinkSteerAdmission.evaluate(
            readiness: AgentSessionLinkExecutionRuntime.agentSessionLinkDeliveryReadinessSnapshot(
                session: session, endpointMatchesGrant: true, isClosing: false
            ),
            runStateIsActive: session.runState.isActive, pendingPromptExists: protectedPrompt,
            route: agentSessionLinkManagedSteerRoute(for: session)
        )
        let frame = Self.mcpResidentTaskFrame(text)
        if !attachments.isEmpty {
            guard case .idleTurn = admission else {
                throw MCPError.invalidParams("Wait for the current run to finish before sending attachments.")
            }
            _ = attachmentRuntime
        }
        switch admission {
        case let .blocked(failure):
            // Provider-switch refusals are non-retryable and need user review in the app; surface
            // the definite reason rather than a busy hint a client would poll past forever.
            switch failure {
            case .providerSwitchUnconfirmed, .providerHandoverNeedsReview:
                throw MCPError.invalidParams("Task input not submitted: provider switch pending. \(failure.message)")
            default:
                throw MCPError.invalidParams(Self.mcpResidentBusyError)
            }
        case let .steer(route):
            let sink = AgentSessionLinkManagedSteerSink()
            let turn = AgentNoncomposerTurn(endpoint: endpoint, providerText: frame, sink: sink)
            guard submitNoncomposerSteer(
                tabID: session.tabID, session: session, displayText: frame,
                turn: turn, route: route, workflow: workflow
            ) else { throw MCPError.invalidParams(Self.mcpResidentBusyError) }
            let outcome = await sink.awaitOutcome(timeoutSeconds: AgentSessionLinkExecutionRuntime.agentSessionLinkManagedSteerOutcomeTimeoutSeconds)
            switch outcome {
            case let .delivered(state):
                switch state {
                case .deliveredToWaitingInstruction: return .deliveredIntoWaitingContinuation
                case .queuedFollowUp: return .queuedFollowUp
                case .queuedInterrupt: return route == .claudeInterrupt ? .queuedClaudeInterrupt : .queuedACPInterrupt
                default: return .dispatchedCodexTurn
                }
            case .notAccepted: throw MCPError.invalidParams(Self.mcpResidentBusyError)
            case .unconfirmed: throw MCPError.invalidParams(Self.mcpResidentUnconfirmedError)
            }
        case .idleTurn:
            guard let submitTarget = makeComposerSubmitTarget(tabID: session.tabID, session: session),
                  submitTarget.route == .existingAgentSession,
                  submitTarget.expectedSourceAgentSessionID == endpoint.sessionID
            else { throw MCPError.invalidParams(Self.mcpResidentBusyError) }
            let attempt = AgentComposerSubmitAttempt(
                id: UUID(), target: submitTarget, inputRevision: 0, noticeRevision: 0, rawDraftSnapshot: ""
            )
            guard case let .claimed(claim) = claimComposerSubmitAttempt(attempt, requireActiveTabOwnership: false) else {
                throw MCPError.invalidParams(Self.mcpResidentBusyError)
            }
            let stopFence = AgentRunStartStopFence(session: session)
            let payload = AgentSessionLinkMessageEnvelope.providerPayload(
                envelope: frame, workflow: workflow,
                includeBuiltInSessionCleanupGuidance: GlobalSettingsStore.shared.showBuiltInWorkflowCleanupGuidance()
            )
            let outcome = await linkExecutionRuntime.persistAndStartNoncomposerTurn(
                session: session, tabID: session.tabID, workspaceID: endpoint.workspaceID,
                claim: claim, displayText: frame, providerMessage: payload, workflow: workflow,
                attribution: nil, stopFence: stopFence, attachments: attachments
            ) {
                targetIsCurrent() && self.composerSubmitRuntime.isCurrent(claim) && stopFence.permitsStart(of: session)
                    && AgentSessionLinkDeliveryReadiness.failure(snapshot: AgentSessionLinkExecutionRuntime.agentSessionLinkDeliveryReadinessSnapshot(
                        session: session, endpointMatchesGrant: true, isClosing: false,
                        ignoresComposerSubmissionInFlight: true,
                        ignoresProviderSwitchStalenessAfterAcceptance: true
                    )) == nil
            }
            switch outcome {
            case let .delivered(delivery) where delivery.deliveryState == .runStarted: return .startedRun
            case .blocked(.persistenceFailed):
                throw MCPError.invalidParams("Client task input was not dispatched because its transcript could not be saved. Check the session in the app before retrying.")
            case let .blocked(failure) where failure == .providerSwitchUnconfirmed
                || failure == .providerHandoverDoesNotFit || failure == .providerHandoverNeedsReview:
                // Refused before the row was persisted; the "input was recorded" fallback would
                // misreport the outcome and hide that only the user can resolve the handover.
                throw MCPError.invalidParams("Task input not submitted: provider switch pending. \(failure.message)")
            default: throw MCPError.invalidParams(Self.mcpResidentUnconfirmedError)
            }
        }
    }
}
