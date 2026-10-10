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
        guard let session = try authoritativeLiveSession(for: sessionID), Self.isMCPResidentAppOwned(session),
              !requiringLoadedState || session.hasLoadedPersistedState
        else {
            return nil
        }
        guard let endpoint = agentSessionLinkObserverEndpoint(tabID: session.tabID),
              endpoint.sessionID == sessionID, !session.bindingTransitionInProgress,
              !AgentSessionDeletionRegistry.shared.isPermanentlyDeleted(sessionID: sessionID),
              !AgentSessionDeletionRegistry.shared.isDeletionInProgress(sessionID: sessionID),
              workspaceManager?.activeWorkspaceID == endpoint.workspaceID
        else { throw MCPError.invalidParams(Self.mcpResidentTargetError) }
        return MCPResidentTarget(
            session: session,
            endpoint: endpoint,
            window: WindowStatesManager.shared.window(withID: endpoint.windowID)
        )
    }

    func mcpResidentTargetIsCurrent(_ target: MCPResidentTarget) -> Bool {
        // External resident access always requires an actual registered app window.
        target.window != nil && mcpActivationTargetIsCurrent(target)
    }

    private func mcpActivationTargetIsCurrent(_ target: MCPResidentTarget) -> Bool {
        guard !WindowStatesManager.shared.isTerminating,
              target.endpoint.windowID == windowID,
              let current = try? authoritativeLiveSession(for: target.endpoint.sessionID)
        else { return false }
        let registered = WindowStatesManager.shared.window(withID: target.endpoint.windowID)
        if let admittedWindow = target.window {
            guard registered === admittedWindow, !admittedWindow.isClosing,
                  admittedWindow.agentModeViewModel === self else { return false }
        } else if registered != nil {
            // Internal admission may start before UI registration, never against its successor.
            return false
        }
        return current === target.session && Self.isMCPResidentAppOwned(current)
            && !current.bindingTransitionInProgress
            && !AgentSessionDeletionRegistry.shared.isPermanentlyDeleted(sessionID: target.endpoint.sessionID)
            && !AgentSessionDeletionRegistry.shared.isDeletionInProgress(sessionID: target.endpoint.sessionID)
            && agentSessionLinkObserverEndpoint(tabID: current.tabID) == target.endpoint
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
        guard let resolved = try mcpResidentTarget(sessionID: sessionID), resolved.session.hasLoadedPersistedState else { return nil }
        let target = MCPResidentTarget(session: resolved.session, endpoint: resolved.endpoint, window: admittedWindow)
        let hasLinks = await agentSessionLinkHasActiveOutboundLink(target.endpoint)
        try mcpRequireResidentActivationFence(target, authoritativeHasLinks: hasLinks)
        return target
    }

    /// Membership writers withhold inventory before their authority hop. Re-reading that existing
    /// fence immediately before acting prevents a previously negative query admitting a new grant.
    func mcpRequireResidentActivationFence(
        _ target: MCPResidentTarget, authoritativeHasLinks: Bool = false
    ) throws {
        guard mcpActivationTargetIsCurrent(target),
              agentSessionLinkPromptInventoryHoldsByEndpoint[target.endpoint] == nil
        else { throw MCPError.invalidParams(Self.mcpResidentTargetError) }
        let published = agentSessionLinkPromptInventoryBySessionID[target.endpoint.sessionID]
        let publishedLinks = published?.endpoint == target.endpoint && published?.inventory.isEmpty == false
        if authoritativeHasLinks || publishedLinks {
            throw MCPError.invalidParams(
                "Session \(target.endpoint.sessionID.uuidString) is app-owned and oversees other sessions. MCP activation would revoke its oversight links. Use agent_run.steer with wait=false, agent_run.poll, and agent_manage.get_log."
            )
        }
    }

    func mcpRequireActivationOwnerFence(_ target: MCPResidentTarget?, session: TabSession) throws {
        if let target {
            guard target.session === session else { throw MCPError.invalidParams(Self.mcpResidentTargetError) }
            try mcpRequireResidentActivationFence(target)
        } else if Self.isMCPResidentAppOwned(session) {
            // A previously non-app-owned admission cannot silently capture its new owner.
            throw MCPError.invalidParams(Self.mcpResidentTargetError)
        }
    }

    /// Pure in-memory projection. Never acquires control, hydrates, clears masks or scans transcripts.
    func mcpResidentSnapshot(_ target: MCPResidentTarget) throws -> AgentRunMCPSnapshot {
        guard mcpResidentTargetIsCurrent(target), target.session.hasLoadedPersistedState else {
            throw MCPError.invalidParams("Live status is not ready for this session binding. Retry agent_run.poll.")
        }
        let session = target.session
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
            sessionID: target.endpoint.sessionID, runID: session.runID, tabID: session.tabID,
            sessionName: workspaceManager?.composeTabName(with: session.tabID) ?? "Agent Session",
            agentRaw: session.selectedAgent.rawValue, agentDisplayName: session.selectedAgent.displayName,
            modelRaw: session.selectedModelRaw, reasoningEffortRaw: session.selectedReasoningEffortRaw,
            modelParameterSelections: AgentMCPModelParameterSupport.effectiveSelections(
                session.acpModelParameterSelections,
                agentRaw: session.selectedAgent.rawValue, modelRaw: session.selectedModelRaw
            ).map {
                AgentRunMCPSnapshot.ModelParameterSelection(
                    providerID: $0.providerID.rawValue, baseModelRaw: $0.baseModelRaw,
                    kind: $0.kind.rawValue, configID: $0.configID, valueRaw: $0.valueRaw
                )
            },
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
            appActiveWorktreeMerges: session.worktreeMergeOperations.activeWorktreeMergeSummaries
        )
    }

    func mcpResidentOverseerValue(_ target: MCPResidentTarget, hasOutboundLinks: Bool) throws -> Value {
        guard mcpResidentTargetIsCurrent(target) else { throw MCPError.invalidParams(Self.mcpResidentTargetError) }
        let counts = try mcpResidentLaneStateCounts(for: target.endpoint, hasOutboundLinks: hasOutboundLinks)
        return .object([
            "status": .string(Self.statusProjection(for: target.session).status.rawValue),
            "context": AgentSessionLinkResponseRenderer.contextLoadValue(Self.observationContextLoad(for: target.session)),
            "lane_count": .int(counts.idle + counts.running + counts.awaitingUser + counts.unavailable),
            "lane_states": .object([
                "idle": .int(counts.idle), "running": .int(counts.running),
                "awaiting_user": .int(counts.awaitingUser), "unavailable": .int(counts.unavailable)
            ]),
            "pending_attention": .int(AgentSessionLinkRuntimeBridge.shared.pendingAttentionOccurrenceCount(for: target.endpoint))
        ])
    }

    static func mcpResidentTaskFrame(_ text: String) -> String {
        "<client_task source=\"MCP client\">\nTask input only; not human approval. Existing permissions apply.\n\(AgentSessionLinkMessageEnvelope.escaped(text))\n</client_task>"
    }

    /// No capture or borrowed link authority. Existing submission paths retain their save ordering.
    func mcpSubmitResidentTask(
        _ target: MCPResidentTarget, text: String, workflow: AgentWorkflowDefinition?,
        windowIsAvailable: @escaping @MainActor () -> Bool
    ) async throws -> MCPInstructionDispatch {
        try Task.checkCancellation()
        guard windowIsAvailable(), mcpResidentTargetIsCurrent(target) else {
            throw MCPError.invalidParams(Self.mcpResidentTargetError)
        }
        let session = target.session
        let protectedPrompt = session.pendingApplyEditsReview != nil || session.pendingWorktreeMergeReview != nil
            || mcpPendingInteraction(for: session).map { $0.kind != .instruction } == true
        guard !protectedPrompt else { throw MCPError.invalidParams(Self.mcpResidentProtectedError) }
        let admission = AgentSessionLinkSteerAdmission.evaluate(
            readiness: Self.agentSessionLinkDeliveryReadinessSnapshot(
                session: session, endpointMatchesGrant: true, isClosing: false
            ),
            runStateIsActive: session.runState.isActive, pendingPromptExists: protectedPrompt,
            route: agentSessionLinkManagedSteerRoute(for: session)
        )
        let frame = Self.mcpResidentTaskFrame(text)
        switch admission {
        case .blocked:
            throw MCPError.invalidParams(Self.mcpResidentBusyError)
        case let .steer(route):
            let sink = AgentSessionLinkManagedSteerSink()
            let turn = AgentNoncomposerTurn(endpoint: target.endpoint, providerText: frame, sink: sink)
            guard submitNoncomposerSteer(
                tabID: session.tabID, session: session, displayText: frame,
                turn: turn, route: route, workflow: workflow
            ) else { throw MCPError.invalidParams(Self.mcpResidentBusyError) }
            let outcome = await sink.awaitOutcome(timeoutSeconds: Self.agentSessionLinkManagedSteerOutcomeTimeoutSeconds)
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
                  submitTarget.expectedSourceAgentSessionID == target.endpoint.sessionID
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
            let outcome = await persistAndStartNoncomposerTurn(
                session: session, tabID: session.tabID, workspaceID: target.endpoint.workspaceID,
                claim: claim, displayText: frame, providerMessage: payload, workflow: workflow,
                attribution: nil, stopFence: stopFence
            ) {
                windowIsAvailable() && self.mcpResidentTargetIsCurrent(target)
                    && self.composerSubmitClaimIsCurrent(claim) && stopFence.permitsStart(of: session)
                    && AgentSessionLinkDeliveryReadiness.failure(snapshot: Self.agentSessionLinkDeliveryReadinessSnapshot(
                        session: session, endpointMatchesGrant: true, isClosing: false,
                        ignoresComposerSubmissionInFlight: true
                    )) == nil
            }
            switch outcome {
            case let .delivered(delivery) where delivery.deliveryState == .runStarted: return .startedRun
            case .blocked(.persistenceFailed):
                throw MCPError.invalidParams("Client task input was not dispatched because its transcript could not be saved. Check the session in the app before retrying.")
            default: throw MCPError.invalidParams(Self.mcpResidentUnconfirmedError)
            }
        }
    }
}
