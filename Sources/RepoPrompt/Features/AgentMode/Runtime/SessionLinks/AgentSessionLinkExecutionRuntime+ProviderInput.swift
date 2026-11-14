import Foundation
import RepoPromptAIContracts

extension AgentSessionLinkExecutionRuntime {
    /// Host composition supplies concrete resource snapshots and labels, not an implementation of
    /// augmentation or recovery. The returned hooks retain this scope's existing input/handoff owners.
    func makeProviderInputHooks(
        environmentForSession: @escaping @MainActor (AgentTabSession) -> ManagedInputEnvironment,
        sessionTitle: @escaping @MainActor (AgentTabSession) -> String
    ) -> AgentModeRunService.ProviderInputAssemblyHooks {
        .init(
            buildHeadlessAgentMessage: { [self] session, text, _, attachments in
                commands.input.buildHeadlessAgentMessage(session: session, initialMessageForRun: text, attachments: attachments, links: self)
            },
            augmentUserMessageForProviderSend: { [self] text, attachments, taggedFiles, session, skipsSlashExpansion, isCurrent in
                guard let session else { return .init(text: text, dispatchIsCurrent: { false }) }
                return await prepareProviderMessage(
                    text, session: session, attachments: attachments, taggedFiles: taggedFiles,
                    skipsSlashExpansion: skipsSlashExpansion, environment: environmentForSession(session), isCurrent: isCurrent
                )
            },
            recordTaggedFileFailures: { [weak scope] failures, session in
                guard let scope else { return }
                AgentSessionProviderInputRuntime.recordTaggedFileFailures(failures, session: session, scope: scope)
            },
            stageResumeRecoveryHandoffIfNeeded: { [self] session in
                await prepareResumeRecoveryHandoff(
                    for: session, sourceTitle: sessionTitle(session), environment: environmentForSession(session)
                ).permitsFreshSession
            },
            prependPendingHandoffIfNeeded: { [weak scope] text, session in scope?.handoff.prependPendingHandoffIfNeeded(text, session: session) ?? text },
            recordPendingHandoffSendOutcome: { [weak scope] session, sent in scope?.handoff.recordSendOutcome(for: session, didSend: sent) },
            claimAgentSessionLinkPrompt: { [self] session, dispatch in agentSessionLinkPromptClaimOutcome(for: session, dispatchID: dispatch) },
            acquireAgentSessionLinkPhysicalDispatch: { [self] session, dispatch in agentSessionLinkAcquirePhysicalDispatch(for: session, dispatchID: dispatch) },
            recordAgentSessionLinkPhysicalDispatchNotAttempted: { [self] session, dispatch in agentSessionLinkRecordPhysicalDispatchNotAttempted(for: session, dispatchID: dispatch) },
            recordAgentSessionLinkPhysicalDispatchFailure: { [self] session, dispatch in agentSessionLinkRecordPhysicalDispatchFailure(for: session, dispatchID: dispatch) },
            acceptAgentSessionLinkPrompt: { [self] session, context, claim in acceptAgentSessionLinkDispatch(session: session, context: context, claim: claim) },
            proveAgentSessionLinkProviderInput: { [self] session, claim in await agentSessionLinkProveProviderInput(for: session, claim: claim) },
            handoffAgentSessionLinkProviderInput: { [self] session, dispatch, claim, proof in agentSessionLinkHandoffProviderInput(for: session, dispatchID: dispatch, claim: claim, proof: proof) }
        )
    }

    func prepareProviderMessage(
        _ text: String, session: AgentTabSession, attachments: [AgentFileAttachment],
        taggedFiles: [AgentTaggedFileAttachment], skipsSlashExpansion: Bool,
        environment: ManagedInputEnvironment, isCurrent: @escaping @MainActor () -> Bool
    ) async -> AgentSessionProviderInputRuntime.ProviderMessage {
        guard commands.isAvailable(), let owner = scope, let command = try? owner.admit(session: session) else {
            return .init(text: text, dispatchIsCurrent: { false })
        }
        var capturedWorkspace: AgentSessionProviderInputRuntime.WorkspaceSource?
        let resources: @MainActor () -> Bool = {
            self.commands.isAvailable() && command.isCurrent && environment.workspaceID == command.identity.workspaceID
                && environment.resourcesAreCurrent() && (capturedWorkspace?.isCurrent() ?? true) && !Task.isCancelled
        }
        let admission: @MainActor () -> Bool = { resources() && isCurrent() }
        guard admission() else { return .init(text: text, dispatchIsCurrent: { false }) }
        var failures: [AgentSessionProviderInputRuntime.ExplicitFileFailure] = []
        let prepared: String
        let providerLaunchInput: AgentProviderLaunchInput?
        do {
            prepared = try await commands.input.augmentUserMessage(
                text, attachments: attachments, taggedFileAttachments: taggedFiles, agent: session.selectedAgent,
                workspacePaths: commands.workspacePaths(), workspace: {
                    let source = try await self.commands.inputWorkspace(session, command)
                    capturedWorkspace = source
                    return source
                },
                session: session, handoff: owner.handoff, ignoresPendingHandoff: false,
                skipsSlashExpansion: skipsSlashExpansion, isCurrent: admission, onTaggedFileFailures: { failures = $0 }
            )
            guard admission() else { return .init(text: text, dispatchIsCurrent: { false }) }
            providerLaunchInput = if session.selectedAgent == .codexExec || session.selectedAgent.usesClaudeNativeRuntime {
                try await environment.captureProviderLaunchInput(command)
            } else { nil }
        } catch {
            return .init(text: text, dispatchIsCurrent: { false })
        }
        guard admission(), await environment.validateResources(command), admission(),
              await capturedWorkspace?.validate() ?? true, admission()
        else {
            return .init(text: text, dispatchIsCurrent: { false })
        }
        return .init(text: prepared, failures: failures, dispatchIsCurrent: resources, validateResources: {
            guard resources(), await environment.validateResources(command), resources(),
                  await capturedWorkspace?.validate() ?? true else { return false }
            return resources()
        }, providerLaunchInput: providerLaunchInput)
    }

    func prepareResumeRecoveryHandoff(
        for session: AgentTabSession, sourceTitle: String, environment: ManagedInputEnvironment,
        command suppliedCommand: AgentSessionRuntimeStore.Command? = nil
    ) async -> AgentSessionHandoffRuntime.RecoveryResult {
        guard commands.isAvailable(), let owner = scope, let membership = owner.membership(of: session),
              environment.resourcesAreCurrent() else { return .refused }
        // Initial worktree preparation already owns an explicit creation command. Preserve that
        // exact requirement instead of reconstructing restored admission before its first save.
        // A stale supplied command must never fall back to today's writer or creation owner.
        let command: AgentSessionRuntimeStore.Command?
        if let suppliedCommand {
            guard suppliedCommand.writer.scope === owner, suppliedCommand.writer.session === session,
                  suppliedCommand.isCurrent else { return .refused }
            command = suppliedCommand
        } else {
            command = try? owner.admit(session: session)
        }
        // A legacy unbound local draft retains its exact slot; bound recovery requires the
        // captured command, either restored or the caller's explicit creation capability.
        if let workspaceID = session.persistentSessionBindingIdentity?.workspaceID {
            guard command != nil, environment.workspaceID == workspaceID else { return .refused }
        }
        if owner.handoff.canReuseRecovery(for: session) { return .unchanged }
        let cutoff = session.items.last(where: { $0.kind != .thinking })?.id
        let transcript: AgentTranscript = if !session.transcript.turns.isEmpty { session.transcript }
        else {
            AgentTranscriptIO.buildTranscript(
                from: session.items, nextSequenceIndex: (session.items.map(\.sequenceIndex).max() ?? -1) + 1,
                policy: .canonical, compact: false
            )
        }
        let valid = cutoff.map { AgentTranscriptIO.isValidHandoffExportCutoffRowID($0, in: transcript) } ?? true
        guard let preparation = owner.handoff.prepareRecovery(
            for: session, sourceTabName: AgentSessionRestoreSupport.normalizedSessionTitle(sourceTitle),
            transcriptXML: AgentTranscriptIO.buildForkTranscriptXML(from: valid ? transcript : .empty, upToRowID: valid ? cutoff : nil)
        ) else { return .refused }
        let recoveryIsCurrent: @MainActor () -> Bool = {
            self.commands.isAvailable() && !Task.isCancelled && (command?.isCurrent ?? membership.permitsBindingPreparation)
                && environment.resourcesAreCurrent()
        }
        guard recoveryIsCurrent() else { return .refused }
        let input: AgentSessionProviderInputRuntime.InitialThreadInput?
        do { input = try await commands.initialThreadInput(session, command) }
        catch { return .refused }
        guard recoveryIsCurrent() else { return .refused }
        // Bound recovery may not turn an unavailable canonical context into a fresh empty thread.
        guard input != nil || command == nil else { return .refused }
        let context: String?
        if let input {
            let values = await commands.input.initialThreadContext(input)
            guard recoveryIsCurrent() else { return .refused }
            let block = AgentSessionProviderInputRuntime.composeInitialThreadMessage(
                initialMessage: "", fileTree: values.fileTree, promptText: values.promptText
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            context = block.isEmpty ? nil : block
        } else { context = nil }
        guard recoveryIsCurrent(), await environment.validateResources(command), recoveryIsCurrent(),
              await input?.workspace.validate() ?? true, input?.workspace.isCurrent() ?? true, recoveryIsCurrent(),
              let staged = owner.handoff.stageRecovery(preparation, initialThreadContextBlock: context) else { return .refused }
        return .staged(staged)
    }
}
