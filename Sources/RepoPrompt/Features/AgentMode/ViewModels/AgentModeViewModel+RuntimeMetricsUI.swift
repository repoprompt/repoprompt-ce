import Foundation

@MainActor
extension AgentModeViewModel {
    func syncRuntimeMetricsUIState(
        liveSelectedFileCount: Int? = nil,
        liveSelectionSummary: AgentContextSelectionSummary? = nil
    ) {
        #if DEBUG
            test_syncRuntimeMetricsCallCount += 1
        #endif
        let sessionConfiguredContextWindow = sidebarConfiguredContextWindow(for: activeSession)
        ui.runtimeMetrics.update(
            transcriptSnapshot: activeTranscriptAnalyticsSnapshot,
            codexUsage: contextUsage,
            liveSelectedFileCount: liveSelectedFileCount,
            liveSelectionSummary: liveSelectionSummary,
            selectedAgent: selectedAgent,
            selectedModelRaw: selectedModelRaw,
            sessionConfiguredContextWindow: sessionConfiguredContextWindow
        )
    }

    func sidebarConfiguredContextWindow(for session: TabSession?) -> Int? {
        guard let session, session.selectedAgent.usesClaudeNativeRuntime else { return nil }
        let key = provisionalClaudeContextWindowKey(for: session)
        let sessionValue = key != nil && session.claudeConfiguredContextWindowKey == key
            ? session.claudeConfiguredContextWindow
            : nil
        return sessionValue
            ?? key.flatMap { provisionalClaudeContextWindowResolver.cachedConfiguredContextWindow(for: $0) }
    }

    func syncSpawnResolvedClaudeConfiguredContextWindow(
        _ value: Int?,
        launchKey: ClaudeProvisionalContextWindowResolver.Key,
        for session: TabSession
    ) {
        session.claudeConfiguredContextWindow = value
        session.claudeConfiguredContextWindowKey = launchKey
        provisionalClaudeContextWindowResolver.store(value, for: launchKey)
        if session.tabID == currentTabID {
            syncRuntimeMetricsUIState()
        }
    }

    func scheduleProvisionalClaudeContextWindowResolutionForActiveSession(reason _: String) {
        guard let session = activeSession,
              let key = provisionalClaudeContextWindowKey(for: session)
        else {
            return
        }
        guard !provisionalClaudeContextWindowResolver.hasCachedValue(for: key),
              !provisionalClaudeContextWindowInFlightKeys.contains(key)
        else {
            return
        }

        provisionalClaudeContextWindowInFlightKeys.insert(key)

        Task.detached(priority: .utility) { [weak self, key] in
            let environmentSnapshot = await ProcessEnvironmentBuilder.build(
                ProcessEnvironmentRequest(purpose: .claudeNative)
            ).environment
            let value = ClaudeProvisionalContextWindowResolver.resolveUncachedConfiguredContextWindow(
                for: key,
                environmentSnapshot: environmentSnapshot
            )
            await MainActor.run { [weak self] in
                self?.completeProvisionalClaudeContextWindowResolution(value, for: key)
            }
        }
    }

    func completeProvisionalClaudeContextWindowResolution(
        _ value: Int?,
        for key: ClaudeProvisionalContextWindowResolver.Key
    ) {
        provisionalClaudeContextWindowInFlightKeys.remove(key)
        if !provisionalClaudeContextWindowResolver.hasCachedValue(for: key) {
            provisionalClaudeContextWindowResolver.store(value, for: key)
        }
        guard let active = activeSession,
              provisionalClaudeContextWindowKey(for: active) == key
        else {
            return
        }
        syncRuntimeMetricsUIState()
    }

    func provisionalClaudeContextWindowKey(for session: TabSession) -> ClaudeProvisionalContextWindowResolver.Key? {
        guard session.selectedAgent.usesClaudeNativeRuntime else { return nil }
        let workspacePath = AgentWorktreeRuntimeWorkspaceResolver.standardizedWorkspacePath(try? effectiveWorkspacePath(for: session))
        return ClaudeProvisionalContextWindowResolver.Key(
            agentKind: session.selectedAgent,
            modelRaw: session.selectedModelRaw,
            workspacePath: workspacePath
        )
    }
}
