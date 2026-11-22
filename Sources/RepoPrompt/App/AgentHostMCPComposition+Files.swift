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
        let requireCurrent: @MainActor @Sendable () async throws -> Void
    }

    func captureHostFileInvocation(_ invocation: ToolInvocationContext) async throws -> HostFileInvocation {
        guard let activation = workspaceActivation, let base = activation.catalogFileLease else {
            throw MCPFileToolAuthorityFailure.unavailable
        }
        let connection = try route.fileReadConnection(metadata: invocation.metadata, workspaceID: base.snapshot.document.workspaceID)
        guard let command = hostFileCommand(connection) else { throw MCPFileToolAuthorityFailure.superseded }
        let lease = try await base.capture(workspaceID: command.identity.workspaceID) {
            activation.executionTab(in: $0, command: command) != nil
        }
        guard let tab = activation.executionTab(in: lease.snapshot, command: command) else {
            throw MCPFileToolAuthorityFailure.superseded
        }
        let store = lease.resources.files
        let lookup = try await AgentWorkspaceLookupContextResolver.requiredLookupContext(
            source: connection.lookupSource, visibleRoots: lease.roots, store: store, usesRetainedRoots: true
        )
        let lifetime: WorkspaceSessionRootLifetimeSnapshot?
        if let projection = lookup.bindingProjection {
            lifetime = await store.sessionBoundRootScopeValidationSnapshot(lookup.rootScope, expectedPhysicalRoots: projection.physicalRootRefs)
            guard lifetime != nil else { throw MCPFileToolAuthorityFailure.worktreeScopeUnavailable }
        } else { lifetime = nil }
        let selectionCommit = HostSelectionCommitReceipt()
        let requireCurrent: @MainActor @Sendable () async throws -> Void = { [weak self] in
            try Task.checkCancellation()
            let workspaceIsCurrent = if let committed = selectionCommit.snapshot {
                await lease.resources.contexts?.workspaceSnapshot(command.identity.workspaceID) == committed
            } else { await lease.isCurrent() }
            guard let self, workspaceIsCurrent,
                  await ServerNetworkManager.shared.validateToolInvocationContext(
                      invocation, expectedWindowID: routeID, expectedServerViewModelIdentity: ObjectIdentifier(route)
                  ) else { throw MCPFileToolAuthorityFailure.superseded }
            if let lifetime, await !lifetime.isCurrent() { throw MCPFileToolAuthorityFailure.worktreeScopeUnavailable }
            guard lease.rootsAreCurrent, hostFileCommand(connection)?.identity == command.identity,
                  activation.executionTab(in: selectionCommit.snapshot ?? lease.snapshot, command: command)?.selection
                  == (selectionCommit.selection ?? tab.selection)
            else {
                throw MCPFileToolAuthorityFailure.superseded
            }
        }
        try await requireCurrent()
        return .init(lease: lease, tab: tab, lookup: lookup, command: command, connection: connection, selectionCommit: selectionCommit, requireCurrent: requireCurrent)
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
                    _ = try await activation.commitHostSelection(
                        updated, replacing: origin.tab.selection, in: origin.lease.snapshot, command: origin.command,
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
