import Foundation
import RepoPromptDomainRuntime

extension AgentSessionRuntimeHost {
    /// Policy issuance captures the originating writer and startup before the provider connects.
    /// The returned resolver may read fresh canonical bytes only for that same carrier.
    func captureProviderContext(runID: UUID, tabID: UUID?) -> MCPHostRouteResources.ProviderContextResolver? {
        guard let activation = workspaceActivation, activation.owns(scope: scope, route: route),
              let workspaceID = activation.key.owner.workspaceID
        else { return nil }
        let matches = scope.sessions.values.filter { $0.runID == runID }
        guard matches.count == 1, let session = matches.first,
              tabID.map({ $0 == session.tabID }) ?? true,
              let command = try? scope.admit(session: session, expectedWorkspaceID: workspaceID),
              let writer = AgentSessionRuntimeStore.WriterReceipt(command)
        else { return nil }

        let attemptID = session.activeRunAttemptID
        let idleStartup = attemptID == nil ? codexCoordinator.captureProviderStartupClaim(for: session) : nil
        guard attemptID != nil || idleStartup != nil else { return nil }
        let stopFence = AgentRunStartStopFence(session: session)
        let bindings = session.worktreeBindings
        let sessionID = command.identity.sessionID
        let context = DomainContextIdentity(workspaceID: workspaceID, contextID: session.tabID)
        let routeID = route.identity.routeID
        let isCurrent: @MainActor @Sendable () -> Bool = { [weak self, weak activation, weak session] in
            guard let self, let activation, let session else { return false }
            return !Task.isCancelled && activation.owns(scope: scope, route: route)
                && writer.disposition(for: session) == .current && stopFence.permitsStart(of: session)
                && session.runID == runID && session.activeRunAttemptID == attemptID
                && (idleStartup?() ?? true) && session.worktreeBindings == bindings
        }
        guard isCurrent() else { return nil }

        return { [weak activation] in
            guard isCurrent(), let activation,
                  let workspace = await activation.authority.canonicalWorkspaceSnapshot(workspaceID),
                  workspace.health != .removed, isCurrent()
            else { return nil }
            let carriers = workspace.contexts.filter { $0.metadata.identity == context && $0.health != .removed }
            guard carriers.count == 1, let carrier = carriers.first,
                  let tab = try? JSONDecoder().decode(ComposeTabState.self, from: carrier.metadata.documentBytes),
                  tab.id == context.contextID, tab.activeAgentSessionID == sessionID, isCurrent()
            else { return nil }
            return .init(snapshot: .init(
                tabID: tab.id, windowID: routeID, workspaceID: workspaceID, promptText: tab.promptText,
                selection: tab.selection, selectionRevision: carrier.revisions.workingRevision,
                selectedMetaPromptIDs: tab.selectedMetaPromptIDs,
                selectedContextBuilderPromptIDs: tab.contextBuilder.selectedContextBuilderPromptIDs,
                tabName: tab.name, runID: runID, activeAgentSessionID: sessionID,
                worktreeBindings: bindings, explicitlyBound: false
            ), isCurrent: isCurrent, validateCarrier: { [weak activation] in
                guard isCurrent(), let latest = await activation?.authority.canonicalWorkspaceSnapshot(workspaceID),
                      latest.health != .removed else { return false }
                let carrierStillBound = latest.contexts.contains {
                    $0.metadata.identity == context && $0.health != .removed
                        && $0.metadata.activeAgentSessionID == sessionID
                }
                return carrierStillBound && isCurrent()
            })
        }
    }
}
