import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptMCPServer
import RepoPromptWorkspaceContext
import RepoPromptWorkspaceCore

extension AgentSessionRuntimeHost {
    @MainActor
    final class HostSelectionCommitReceipt {
        var snapshot: DomainWorkspaceSnapshot?
        var selection: StoredSelection?
    }

    @MainActor
    struct HostFileInvocation {
        let lease: AgentHostWorkspaceResources.Lease
        let tab: ComposeTabState
        let lookup: WorkspaceLookupContext
        let command: AgentSessionRuntimeStore.Command
        let connection: MCPHostRouteResources.FileReadConnection
        let selectionCommit: HostSelectionCommitReceipt
        let currentWorkspace: @MainActor @Sendable () async throws -> DomainWorkspaceSnapshot

        var requireCurrent: @MainActor @Sendable () async throws -> Void {
            let read = currentWorkspace
            return { _ = try await read() }
        }
    }

    func captureHostFileInvocation(_ invocation: ToolInvocationContext) async throws -> HostFileInvocation {
        guard let activation = workspaceActivation, let base = activation.catalogFileLease else {
            throw MCPFileToolAuthorityFailure.unavailable
        }
        let connection = try route.fileReadConnection(metadata: invocation.metadata, workspaceID: base.snapshot.document.workspaceID)
        guard let command = hostFileCommand(connection) else { throw MCPFileToolAuthorityFailure.superseded }
        let lease = try await base.capture(workspaceID: command.identity.workspaceID, authority: .canonical) {
            activation.executionTab(in: $0, command: command) != nil
        }
        guard let tab = activation.executionTab(in: lease.snapshot, command: command) else {
            throw MCPFileToolAuthorityFailure.superseded
        }
        let store = lease.resources.files
        let lookup = try await lease.lookupContext(for: connection.lookupSource)
        let lifetime: WorkspaceSessionRootLifetimeSnapshot?
        if let projection = lookup.bindingProjection {
            lifetime = await store.sessionBoundRootScopeValidationSnapshot(lookup.rootScope, expectedPhysicalRoots: projection.physicalRootRefs)
            guard lifetime != nil else { throw MCPFileToolAuthorityFailure.worktreeScopeUnavailable }
        } else { lifetime = nil }
        let selectionCommit = HostSelectionCommitReceipt()
        let originalPaths = Set(lease.roots.compactMap { StandardizedPath.canonicalWorkspaceRootPath($0.fullPath) })
        let currentWorkspace: @MainActor @Sendable () async throws -> DomainWorkspaceSnapshot = { [weak self] in
            try Task.checkCancellation()
            guard let self, await lease.retainedRootsAreCurrent(),
                  await ServerNetworkManager.shared.validateToolInvocationContext(
                      invocation, expectedWindowID: routeID, expectedServerViewModelIdentity: ObjectIdentifier(route)
                  ) else { throw MCPFileToolAuthorityFailure.superseded }
            if let lifetime, await !lifetime.isCurrent() { throw MCPFileToolAuthorityFailure.worktreeScopeUnavailable }
            // Presentation can publish a different read overlay or save unrelated fields when
            // leaving this workspace. Neither changes the admitted execution incarnation.
            guard let current = await activation.authority.canonicalWorkspaceSnapshot(command.identity.workspaceID),
                  !Task.isCancelled, lease.rootsAreCurrent, workspaceActivation === activation,
                  hostFileCommand(connection)?.identity == command.identity,
                  current.health != .removed, !lease.snapshot.health.acceptsMutations || current.health.acceptsMutations,
                  current.document.fileURL == lease.snapshot.document.fileURL,
                  current.document.metadata.canonicalLoadableRepoPathSet == originalPaths,
                  activation.executionTab(in: current, command: command)?.selection == (selectionCommit.selection ?? tab.selection)
            else { throw MCPFileToolAuthorityFailure.superseded }
            // isCurrent() also checks disk before this last authority read. The lifetime
            // generation check below closes the extra suspension without replacing roots.
            if let lifetime, !lifetime.isGenerationCurrent() { throw MCPFileToolAuthorityFailure.worktreeScopeUnavailable }
            return current
        }
        _ = try await currentWorkspace()
        return .init(lease: lease, tab: tab, lookup: lookup, command: command, connection: connection, selectionCommit: selectionCommit, currentWorkspace: currentWorkspace)
    }

    func executeHostApplyEdits(_ args: [String: Value], invocation: ToolInvocationContext) async throws -> Value {
        guard let activation = workspaceActivation, let interactions = scope.installedInteractions,
              let outer = MCPDomainMutationCommitContext.controller
        else {
            throw MCPFileToolAuthorityFailure.unavailable
        }
        let origin = try await captureHostFileInvocation(invocation)
        guard await ServerNetworkManager.shared.runPurpose(for: origin.connection.connectionID) == .agentModeRun else {
            throw MCPFileToolAuthorityFailure.unavailable
        }
        let requireCurrent = origin.requireCurrent
        let controller = DomainMutationCommitController(
            admitPhysicalTargets: { paths, mappings in
                try await requireCurrent()
                try await outer.admitPhysicalTargets(paths, rootMappings: mappings)
                try await requireCurrent()
            }, physicalMutationGuard: {
                try await requireCurrent()
                let guardReceipt = try await outer.physicalMutationGuard()
                try await requireCurrent()
                return guardReceipt
            }, physicalMutationCapability: {
                try await requireCurrent()
                let capability = try await outer.physicalMutationCapability()
                try await requireCurrent()
                return capability
            }, willCommit: {
                try await requireCurrent()
                try await outer.willCommit()
            }
        )
        let selection = origin.lookup.physicalizeSelection(origin.tab.selection)
        let context = MCPApplyEditsToolProvider.ExecutionContext(
            metadata: invocation.metadata, workspaceID: origin.command.identity.workspaceID, tabID: origin.tab.id,
            store: origin.lease.resources.files, lookup: origin.lookup, approvalStore: interactions.approvalStore,
            approvalScope: ApplyEditsApprovalScope(windowID: routeID, tabID: origin.tab.id),
            capturedSelectedPaths: Set(selection.selectedPaths), requireCurrent: requireCurrent,
            selectCreated: { file in
                guard let file else { return "The file was written, but it is not yet indexed for selection." }
                let path = file.standardizedFullPath
                var slices = selection.slices
                slices.removeValue(forKey: path)
                let updated = origin.lookup.logicalizeSelection(.init(
                    selectedPaths: selection.selectedPaths.contains(path) ? selection.selectedPaths : selection.selectedPaths + [path],
                    manualCodemapPaths: selection.manualCodemapPaths, slices: slices, codemapAutoEnabled: selection.codemapAutoEnabled
                ))
                do {
                    let current = try await origin.currentWorkspace()
                    _ = try await activation.commitHostSelection(
                        updated, replacing: origin.tab.selection, in: current, command: origin.command,
                        connectionID: origin.connection.connectionID, validatesOrigin: {
                            do { try await requireCurrent()
                                return true
                            } catch { return false }
                        }
                    )
                    return nil
                } catch { return "The file was written, but the originating selection changed before it could be updated." }
            }
        )
        return try await MCPDomainMutationCommitContext.controllerTaskLocal.withValue(controller) {
            try await MCPApplyEditsToolProvider.executeHost(args: args, context: context)
        }
    }
}
