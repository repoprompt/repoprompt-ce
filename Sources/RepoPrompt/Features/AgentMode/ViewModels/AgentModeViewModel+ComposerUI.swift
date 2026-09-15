import Foundation

extension AgentModeViewModel {
    func makeComposerProps(tabID explicitTabID: UUID? = nil) -> AgentComposerProps {
        let tabID = explicitTabID ?? currentTabID
        let session = tabID.flatMap { sessions[$0] }
        let isMCPControlled = isMCPControlled(tabID: tabID)
        let isCodexRunActive: Bool = {
            guard selectedAgent == .codexExec, let tabID else { return false }
            return isTabRunning(tabID)
        }()
        let cancelTarget: AgentRunCancelTarget? = {
            guard let tabID,
                  let session,
                  session.runState.isActive,
                  session.runState != .waitingForUser,
                  session.runID != nil
            else { return nil }
            return makeRunCancelTarget(tabID: tabID, session: session)
        }()
        let submitTarget = makeComposerSubmitTarget(tabID: tabID, session: session)
        let acpControls = acpModelParameterControls(session: session)
        let acpRunLocksModelControls = session?.runState.isActive == true && !acpControls.isEmpty
        return AgentComposerProps(
            currentTabID: tabID,
            submitTarget: submitTarget,
            attachments: AgentAttachmentStripSnapshot(
                scopeTabID: tabID,
                imageAttachments: pendingImageAttachments,
                taggedFileAttachments: pendingTaggedFileAttachments
            ),
            runState: runState,
            cancelTarget: cancelTarget,
            isAgentBusy: isAgentBusy,
            isWaitingForInstruction: isWaitingForInstruction,
            canUseLinkedAgentSession: hasLinkedAgentSession(for: tabID),
            isCurrentTabMCPControlled: isMCPControlled,
            areModelControlsDisabled: isMCPControlled || acpRunLocksModelControls,
            providerControls: activeProviderControlsBinding,
            isCodexRunActive: isCodexRunActive,
            hasAvailableAgentProviders: hasAvailableAgentProviders,
            canSendWithCurrentProvider: canSendWithCurrentProvider,
            unavailableSelectedAgentMessage: unavailableSelectedAgentMessage,
            selectedAgent: selectedAgent,
            selectedModelRaw: selectedModelRaw,
            selectedModelDisplayName: selectedModelDisplayName,
            selectedReasoningEffortRaw: selectedReasoningEffortRaw,
            selectedReasoningEffortDisplayName: selectedReasoningEffortDisplayName,
            acpModelParameterControls: acpControls,
            availableAgents: availableAgents,
            isProviderPickerLockedForCurrentTab: isProviderPickerLocked(tabID: tabID),
            lockedAgentSelectionMessage: lockedAgentSelectionMessage(tabID: tabID),
            autoEditEnabled: autoEditEnabled,
            stagedSlashCommand: stagedSlashCommandProps(tabID: tabID),
            draftRestorationEvent: draftRestorationEvent.map(AgentDraftRestorationProps.init),
            fileTagLookupContextIdentity: agentWorkspaceLookupContextIdentity(tabID: tabID, session: session)
        )
    }

    private func acpModelParameterControls(session: TabSession?) -> [AgentComposerModelParameterControlProps] {
        guard let providerID = selectedAgent.acpProviderID else { return [] }
        // Pure projection over the held demand-scoped observation (OpenCode) or the static
        // catalogue (Cursor). Never launch discovery from here. While the OpenCode observation
        // is loading/failed/has no usable parameters, this yields no parameter set, so the
        // effort control is omitted while model selection, permissions, and submission stay
        // usable. Every returned choice renders, including a one-option menu.
        // Unwrap the KEY itself and pass its possibly-nil workspacePath separately: optional
        // chaining (`key?.workspacePath`) would collapse "resolution failed" (no key) into
        // "resolved nil-workspace" (key with workspacePath: nil). A held nil-workspace
        // observation resolves only via a constructed nil-workspace key, while a failed
        // authority resolution withholds the control entirely.
        let workspacePath: String?
        if providerID == .openCode {
            guard let key = openCodeParameterDiscoveryKey(session: session, modelRaw: selectedModelRaw) else {
                return []
            }
            workspacePath = key.workspacePath
        } else if let session {
            workspacePath = try? effectiveWorkspacePath(for: session)
        } else {
            workspacePath = workspacePathProvider()
        }
        let resolved = ACPModelParameterResolver.resolve(
            providerID: providerID,
            selectedModelRaw: selectedModelRaw,
            persistedSelections: session?.acpModelParameterSelections ?? [],
            workspacePath: workspacePath,
            openCodeParameters: providerID == .openCode ? openCodeModelParameterObservation : nil
        )
        return resolved.map { parameter in
            .init(
                providerID: providerID,
                kind: parameter.definition.kind,
                baseModelRaw: parameter.baseModelRaw,
                configID: parameter.definition.configID,
                displayName: parameter.definition.displayName,
                selectedValueRaw: parameter.selectedChoice.rawValue,
                selectedDisplayName: parameter.selectedChoice.displayName,
                choices: parameter.definition.choices,
                openCodeDiscoveryKey: providerID == .openCode ? openCodeModelParameterObservation?.key : nil
            )
        }
    }

    func makeComposerSubmitTarget(tabID: UUID?, session: TabSession?) -> AgentComposerSubmitTarget? {
        guard let tabID else { return nil }
        let resolvedSession = session ?? self.session(for: tabID)
        let expectedInitialStartLocation = initialStartLocationProps(tabID: tabID)?.selection
        if workspaceSwitchInFlight, (expectedInitialStartLocation ?? .local) == .local {
            return nil
        }
        guard !resolvedSession.isComposerSubmissionInFlight,
              !resolvedSession.isPreparingInitialWorktree,
              !resolvedSession.isChangingExecutionLocation
        else { return nil }
        let expectedSourceAgentSessionID = composerSourceAgentSessionID(tabID: tabID, session: resolvedSession)
        let hasLinkedSession = hasLinkedAgentSession(for: tabID)
        let route: AgentComposerSubmitTarget.Route
        if hasLinkedSession {
            guard expectedSourceAgentSessionID != nil else { return nil }
            route = .existingAgentSession
        } else {
            guard expectedSourceAgentSessionID == nil else { return nil }
            guard !resolvedSession.runState.isActive,
                  resolvedSession.runID == nil,
                  resolvedSession.activeRunAttemptID == nil
            else { return nil }
            route = .createAgentSessionFromSourceTab
        }

        let expectedRunState = resolvedSession.runState
        let expectedRunID = resolvedSession.runID
        let expectedRunAttemptID = resolvedSession.activeRunAttemptID
        guard !expectedRunState.isActive || expectedRunID != nil else { return nil }
        return AgentComposerSubmitTarget(
            tabID: tabID,
            route: route,
            expectedSourceTabSessionIdentity: ObjectIdentifier(resolvedSession),
            expectedSourceAgentSessionID: expectedSourceAgentSessionID,
            expectedPersistentBindingIdentity: resolvedSession.persistentSessionBindingIdentity,
            expectedBindingTransitionGeneration: resolvedSession.bindingTransitionGeneration,
            expectedRunState: expectedRunState,
            expectedRunID: expectedRunID,
            expectedRunAttemptID: expectedRunAttemptID,
            expectedSubmissionToken: resolvedSession.composerSubmissionToken,
            expectedInitialStartLocation: expectedInitialStartLocation
        )
    }

    func syncComposerUIState(tabID: UUID? = nil) {
        #if DEBUG
            test_syncComposerCallCount += 1
        #endif
        ui.composer.update(makeComposerProps(tabID: tabID))
    }

    func syncAllActiveUIState(tabID: UUID? = nil) {
        #if DEBUG
            AgentModePerfDiagnostics.increment("ui.syncAllActiveUIState", tabID: tabID)
            AgentModePerfDiagnostics.event("ui.syncAllActiveUIState", tabID: tabID)
        #endif
        syncComposerUIState(tabID: tabID)
        syncStatusPillsUIState()
        syncRuntimeMetricsUIState()
        // Sidebar revision should publish only on sidebar-relevant changes (session
        // list, sort, search, visible count). `syncSidebarUIState()` still republishes
        // the snapshot when those inputs differ; callers that truly need to force a
        // sidebar revision bump (e.g. sessions/sessionIndex/run-state mutations) call
        // `syncSidebarUIState(refresh: true)` directly.
        syncSidebarUIState()
        syncTranscriptUIState()
        syncRunInteractionUIState()
    }

    func syncActiveUIState(tabID: UUID? = nil, invalidation: ActiveUIInvalidation) {
        guard !invalidation.isEmpty else { return }
        #if DEBUG
            AgentModePerfDiagnostics.increment("ui.syncActiveUIState", tabID: tabID)
            AgentModePerfDiagnostics.event(
                "ui.syncActiveUIState",
                tabID: tabID,
                fields: [
                    "composer": String(invalidation.contains(.composer)),
                    "status": String(invalidation.contains(.statusPills)),
                    "runtime": String(invalidation.contains(.runtimeMetrics)),
                    "transcript": String(invalidation.contains(.transcript)),
                    "run": String(invalidation.contains(.runInteraction))
                ]
            )
        #endif
        if invalidation.contains(.composer) {
            syncComposerUIState(tabID: tabID)
        }
        if invalidation.contains(.statusPills) {
            syncStatusPillsUIState()
        }
        if invalidation.contains(.runtimeMetrics) {
            syncRuntimeMetricsUIState()
        }
        if invalidation.contains(.transcript) {
            syncTranscriptUIState()
        }
        if invalidation.contains(.runInteraction) {
            syncRunInteractionUIState()
        }
    }
}
