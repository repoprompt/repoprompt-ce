import Foundation

extension AgentModeViewModel {
    enum SwitchboardPairingFailure: Error, LocalizedError {
        case rootRequired, idleRequired, legacySession, identityChanged, runtimeUnavailable

        var errorDescription: String? {
            switch self {
            case .rootRequired: "Pairing is available only for root Codex sessions."
            case .idleRequired: "Wait until this session and its tools, queued work and child agents are idle."
            case .legacySession: "Start a new empty Codex session to pair. Existing ordinary backends cannot be converted."
            case .identityChanged: "The session changed during pairing. Its conversation was retained; try pairing again."
            case .runtimeUnavailable: "The managed runtime could not be verified. This conversation was retained; re-pair to retry."
            }
        }
    }

    /// UI-only explicit consent. Never advertise this method through MCP, and
    /// never accept pairing material from a model or session transcript.
    func pairSwitchboardSession(tabID: UUID, envelopeData: Data) async throws {
        let pairing = try SwitchboardPairingEnvelope.parse(envelopeData)
        let workspaceID = activeWorkspaceIDForSessionIndexOwnership
        let session = await ensureSessionReady(tabID: tabID)
        try Task.checkCancellation()
        guard sessions[tabID] === session, activeWorkspaceIDForSessionIndexOwnership == workspaceID else { throw SwitchboardPairingFailure.identityChanged }
        guard session.selectedAgent == .codexExec, session.parentSessionID == nil else { throw SwitchboardPairingFailure.rootRequired }
        guard codexCoordinator.switchboardSetupRejection(for: session) == nil,
              !switchboardHasActiveOrUnknownDescendants(of: session),
              session.switchboardAccountControl?.isTransactionInFlight != true,
              session.switchboardAccountControl?.isPreparing != true else { throw SwitchboardPairingFailure.idleRequired }
        if let controller = session.codexController, !controller.usesManagedHTTPAccountAdoption { throw SwitchboardPairingFailure.legacySession }
        if !session.requiresSwitchboardPairing,
           session.codexConversationID != nil || session.codexRolloutPath != nil || !session.items.isEmpty { throw SwitchboardPairingFailure.legacySession }
        let retainedThreadID = session.codexConversationID
        if session.codexRolloutPath != nil, retainedThreadID == nil { throw SwitchboardPairingFailure.runtimeUnavailable }

        await session.switchboardAccountControl?.revokeAndWait()
        if let ended = session.codexController as? CodexNativeSessionController,
           await ended.managedAccountTransportHasFullyEnded()
        {
            guard sessions[tabID] === session, session.codexController === ended,
                  activeWorkspaceIDForSessionIndexOwnership == workspaceID,
                  codexCoordinator.switchboardSetupRejection(for: session) == nil,
                  !switchboardHasActiveOrUnknownDescendants(of: session) else { throw SwitchboardPairingFailure.identityChanged }
            // The native actor has settled all startup and process-family teardown.
            // Retire only this proven-ended managed instance, never an unknown or
            // live backend. Conversation metadata is retained for exact resume.
            await codexCoordinator.shutdownCodexSession(session)
        }
        _ = try await mcpResolveOrCreateSessionTarget(tabID: tabID, sessionID: nil, createIfNeeded: true, sessionName: nil)
        try Task.checkCancellation()
        guard sessions[tabID] === session, activeWorkspaceIDForSessionIndexOwnership == workspaceID,
              let sessionID = session.activeAgentSessionID, session.codexConversationID == retainedThreadID,
              codexCoordinator.switchboardSetupRejection(for: session) == nil,
              !switchboardHasActiveOrUnknownDescendants(of: session) else { throw SwitchboardPairingFailure.identityChanged }

        let control = CodexSwitchboardSessionControl()
        session.requiresSwitchboardPairing = true
        session.switchboardAccountControl = control
        session.isDirty = true
        scheduleSave(for: tabID)
        requestUIRefresh(tabID: tabID, urgent: true)
        do {
            // No provider turn and no ordinary-login requirement. A fresh backend
            // starts unauthenticated/ephemeral; retained history may only resume
            // its exact ID, with all fresh-thread fallbacks disabled.
            await codexCoordinator.ensureCodexNativeSession(
                session: session, allowMissingRolloutFallback: false, allowResumeTimeoutFallback: false
            )
            guard sessions[tabID] === session, activeWorkspaceIDForSessionIndexOwnership == workspaceID,
                  session.activeAgentSessionID == sessionID, session.switchboardAccountControl === control,
                  let controller = session.codexController, controller.usesManagedHTTPAccountAdoption,
                  let threadID = session.codexConversationID,
                  retainedThreadID == nil || retainedThreadID == threadID,
                  controller.currentSessionReference?.conversationID == threadID else { throw SwitchboardPairingFailure.identityChanged }
            let scope = CodexAccountAdoptionScope(
                consentID: UUID(),
                sessionID: sessionID,
                controllerGeneration: session.codexControllerGeneration,
                threadID: threadID
            )
            let controllerIdentity = ObjectIdentifier(controller)
            let bindingGeneration = session.bindingTransitionGeneration
            let authorization = control.authorization
            let bridge = SwitchboardBridgeClient(pairing: pairing, scope: .init(
                consentID: scope.consentID, sessionID: scope.sessionID,
                controllerGeneration: scope.controllerGeneration, threadID: threadID
            ))
            let runtime = CodexSwitchboardSessionControl.Runtime(
                admission: { [weak self, weak session, weak control] in
                    guard let self, let session, let control,
                          sessions[tabID] === session, activeWorkspaceIDForSessionIndexOwnership == workspaceID,
                          session.activeAgentSessionID == sessionID, session.switchboardAccountControl === control,
                          session.bindingTransitionGeneration == bindingGeneration,
                          session.codexControllerGeneration == scope.controllerGeneration,
                          let current = session.codexController, ObjectIdentifier(current) == controllerIdentity,
                          session.codexConversationID == threadID, current.currentSessionReference?.conversationID == threadID else { return nil }
                    return codexCoordinator.switchboardAdmission(
                        for: session,
                        scope: scope,
                        hasActiveChildren: switchboardHasActiveOrUnknownDescendants(of: session)
                    )
                },
                inspect: { try await controller.inspectAccountAdoptionRuntime() },
                reserve: { try await controller.reserveAccountAdoption() },
                finish: { lease, allow in await controller.finishAccountAdoption(lease, allowTurns: allow) },
                install: { grant in try await controller.installAccountAdoptionGrant(grant, authorization: authorization) }
            )
            try await control.connect(scope: scope, bridge: bridge, runtime: runtime)
            control.startPolling()
            session.isDirty = true
            scheduleSave(for: tabID)
        } catch {
            await control.revokeAndWait()
            requestUIRefresh(tabID: tabID, urgent: true)
            // Never expose bridge errors or provider payloads in the UI.
            throw SwitchboardPairingFailure.runtimeUnavailable
        }
    }
}
