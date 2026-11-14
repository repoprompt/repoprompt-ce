import Foundation

extension AgentSessionRuntimeHost {
    /// Capture a request from the supplied writer, then enter the existing startup owner. Never
    /// re-admit a replacement after canonical IO, and never join the worktree producer calling us.
    func startCanonicalRequest(
        command: AgentSessionRuntimeStore.Command, message: String,
        attachments: [AgentFileAttachment] = [], taggedFileAttachments: [AgentTaggedFileAttachment] = [],
        codexFallbackContext: AgentTabSession.CodexFallbackSubmissionContext? = nil,
        autoEffortSelection: AutoEffortTurnSelection? = nil,
        options: AgentDirectRunStartOptions, outcome: AgentRunStartOutcomeRecorder?,
        providerSwitchPreparation: AgentProviderSwitchSendPreparation? = nil
    ) async -> CodexAgentModeCoordinator.NativeSendOutcome? {
        let session = command.writer.session
        var options = options
        let stop = options.stopFence ?? AgentRunStartStopFence(session: session)
        options.stopFence = stop
        let ownership = session.activeRunOwnership
        let runID = session.runID
        let attemptID = session.activeRunAttemptID
        let agent = session.selectedAgent
        let codex = session.codexController
        let claude = session.claudeController
        let acp = session.acpController
        func requestIsCurrent() -> Bool {
            stop.permitsStart(of: session) && session.activeRunOwnership == ownership
                && session.runID == runID && session.activeRunAttemptID == attemptID && session.selectedAgent == agent
                && session.codexController.map(ObjectIdentifier.init) == codex.map(ObjectIdentifier.init)
                && session.claudeController.map(ObjectIdentifier.init) == claude.map(ObjectIdentifier.init)
                && session.acpController.map(ObjectIdentifier.init) == acp.map(ObjectIdentifier.init)
        }
        do {
            try command.requireCurrent()
            guard command.writer.scope === scope, case .restored = command.requirement,
                  let activation = workspaceActivation, activation.isCurrent,
                  let links = scope.linkExecution, requestIsCurrent(), !route.isClosing
            else { throw AgentHostWorkspaceResources.Failure.authorityUnavailable }
            let rootIDs = try await activation.loadedRootIDs(for: command, route: route)
            try Task.checkCancellation()
            try command.requireCurrent()
            guard requestIsCurrent() else {
                throw AgentHostWorkspaceResources.Failure.authorityUnavailable
            }
            let resources = try await captureStartupResources(for: command, rootIDs: rootIDs)
            try Task.checkCancellation()
            try command.requireCurrent()
            guard requestIsCurrent(), resources.isCurrent else {
                throw AgentHostWorkspaceResources.Failure.authorityUnavailable
            }
            return try await scope.startup.start(
                session: session, initialMessage: message, attachments: attachments,
                taggedFileAttachments: taggedFileAttachments, codexFallbackContext: codexFallbackContext,
                autoEffortSelection: autoEffortSelection, directStartOptions: options,
                startOutcome: outcome, providerSwitchPreparation: providerSwitchPreparation,
                claudeCoordinator: claudeCoordinator, links: links,
                environment: makeStartupEnvironment(resources: resources)
            )
        } catch {
            let message = "The originating session or its canonical launch resources are no longer available."
            outcome?.recordStartFailure(message: message)
            return .failed(message: message)
        }
    }

    /// Admission belongs to the continuation producer's scheduling turn. Retain this host and
    /// command in that producer; a delayed launch must not reacquire a replacement writer.
    func makeCanonicalContinuationLaunch(for session: AgentTabSession) -> AgentSessionRunContinuationRuntime.Launch? {
        guard let activation = workspaceActivation, activation.isCurrent, !route.isClosing,
              let workspaceID = activation.key.owner.workspaceID,
              let command = try? scope.admit(session: session, expectedWorkspaceID: workspaceID)
        else { return nil }
        return .init { [self] original, instruction, outcome in
            guard original === command.writer.session else {
                outcome.recordStartFailure(message: "The originating continuation session is unavailable.")
                return
            }
            _ = await startCanonicalRequest(
                command: command, message: instruction.providerText,
                options: .init(skipsSlashExpansion: instruction.skipsSlashExpansion, stopFence: instruction.stopFence),
                outcome: outcome
            )
        }
    }

    /// Only canonical activations replace the compatibility launcher. The closure's weak edge
    /// avoids a host/scope cycle; an admitted invocation retains this exact host through startup.
    func installCanonicalContinuationLauncher() {
        guard workspaceActivation != nil else { return }
        scope.worktrees.terminalContinuationLauncher = { [weak self] command, message, options, outcome in
            guard let self else {
                outcome.recordStartFailure(message: "The originating execution host is unavailable.")
                return
            }
            _ = await startCanonicalRequest(command: command, message: message, options: options, outcome: outcome)
        }
    }
}
