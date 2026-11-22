import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptFoundation
import RepoPromptMCPServer
import RepoPromptSettingsCore
import RepoPromptWorkspaceContext
import RepoPromptWorkspaceCore

extension AgentSessionRuntimeHost {
    /// Route registration contributes the original writer incarnation; workspace/tab identifiers
    /// alone are insufficient when the carrier displays another transcript.
    func hostFileCommand(_ connection: MCPHostRouteResources.FileReadConnection) -> AgentSessionRuntimeStore.Command? {
        guard let sessionID = connection.lookupSource.activeAgentSessionID, let runID = connection.runID,
              let activation = workspaceActivation, activation.owns(scope: scope, route: route),
              activation.savedCarrierSessionID == connection.savedCarrierSessionID,
              route.fileReadConnectionIsCurrent(connection),
              let session = scope.sessions[connection.context.contextID], session.runID == runID,
              connection.runAttemptIDAtBinding.map({ $0 == session.activeRunAttemptID }) ?? true,
              let command = try? scope.admit(session: session, expectedWorkspaceID: connection.context.workspaceID),
              command.identity == connection.writerAtBinding, command.identity.sessionID == sessionID,
              connection.lookupSource.worktreeBindingState.bindings == session.worktreeBindings else { return nil }
        if let origin = AgentSelfMCPCallOrigin.current {
            guard origin.runID == runID, origin.runAttemptID == session.activeRunAttemptID,
                  scope.linkExecution?.agentSessionLinkObserverEndpoint(tabID: session.tabID) == origin.endpoint else { return nil }
        }
        return command
    }

    func makeHostFileReadResources(_ lease: AgentHostWorkspaceResources.Lease) -> MCPFileReadResources {
        .init(workspace: lease, settings: .shared, contentEffects: .init(
            // This route has no advertised Git artifact grant. Ordinary exact paths still use
            // the shared resolver and the run's canonical logical/physical root projection.
            artifact: { _, _, _, _, _, _ in nil },
            selectRead: { [weak self] connection, snapshot, validateResources, lookup, reply, path, physical in
                guard let self, let intent = AutoSliceSelection.readFileSelection(from: reply, fallbackPath: path) else { return nil }
                let ranges: [LineRange]? = if case let .slice(entry) = intent { entry.ranges } else { nil }
                return try await applyHostReadSelection(connection, snapshot: snapshot, validateResources: validateResources, lookup: lookup, files: [physical], slices: ranges.map { [physical: $0] } ?? [:])
            }, selectSearch: { [weak self] connection, snapshot, validateResources, lookup, mode, lines, reply, paths in
                guard let self, !paths.isEmpty else { return nil }
                var slices: [String: [LineRange]] = [:]
                if AutoSliceSelection.shouldSliceFileSearch(mode: mode, contextLines: lines) {
                    let ranges = Dictionary(uniqueKeysWithValues: AutoSliceSelection.searchEntries(from: reply.contentMatchGroups).map { ($0.path, $0.ranges) })
                    for path in paths {
                        let projected = lookup.bindingProjection?.projectedLogicalDisplayPath(forPhysicalPath: path) ?? path
                        if let lines = ranges[projected] { slices[path] = lines }
                    }
                }
                return try await applyHostReadSelection(connection, snapshot: snapshot, validateResources: validateResources, lookup: lookup, files: paths, slices: slices)
            }
        ), hostExecutionTab: { [weak self] snapshot, connection in
            guard let self, let command = hostFileCommand(connection) else { return nil }
            return workspaceActivation?.executionTab(in: snapshot, command: command)
        })
    }

    func executeHostSelection(
        args: [String: Value], invocation: ToolInvocationContext, lease base: AgentHostWorkspaceResources.Lease
    ) async throws -> Value {
        let op = args["op"]?.stringValue ?? "get"
        let mode = args["mode"]?.stringValue ?? "full"
        guard ["full", "slices", "codemap_only"].contains(mode) else { throw MCPError.invalidParams("Unknown selection mode") }
        guard let activation = workspaceActivation, let workspaceID = activation.key.owner.workspaceID else {
            throw MCPFileToolAuthorityFailure.unavailable
        }
        let connection = try route.fileReadConnection(metadata: invocation.metadata, workspaceID: workspaceID)
        guard let original = hostFileCommand(connection) else { throw MCPFileToolAuthorityFailure.unavailable }
        let lease = try await base.capture(workspaceID: workspaceID) { activation.executionTab(in: $0, command: original) != nil }
        guard let tab = activation.executionTab(in: lease.snapshot, command: original) else { throw MCPFileToolAuthorityFailure.superseded }
        let store = lease.resources.files
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        let lookup = try await AgentWorkspaceLookupContextResolver.requiredLookupContext(source: connection.lookupSource, visibleRoots: roots, store: store)
        let lookupLifetime = if let projection = lookup.bindingProjection {
            await store.sessionBoundRootScopeValidationSnapshot(lookup.rootScope, expectedPhysicalRoots: projection.physicalRootRefs)
        } else { nil as WorkspaceSessionRootLifetimeSnapshot? }
        guard lookup.bindingProjection == nil || lookupLifetime != nil else { throw MCPFileToolAuthorityFailure.worktreeScopeUnavailable }
        let physical = lookup.physicalizeSelection(tab.selection)
        let input = MCPServerViewModel.parseSavedOrVisibleSelectionInputs(
            rawPaths: args["paths"]?.arrayValue?.compactMap(\.stringValue) ?? [], slicesValue: args["slices"]
        )
        let paths = lookup.translateInputPaths(input.paths)
        let slices = input.sliceInputs.map { WorkspaceSelectionSliceInput(path: lookup.translateInputPath($0.path), ranges: $0.ranges) }
        let selectionService = WorkspaceSelectionMutationService(store: store, codemapsGloballyDisabled: GlobalSettingsStore.shared.globalCodeMapsDisabled())
        let selection = await computeSavedSelection(
            op: op, mode: mode, physical: physical, paths: paths, input: input, slices: slices,
            service: selectionService, rootScope: lookup.rootScope
        )
        if args["strict"]?.boolValue == true, selection.selection == physical, !selection.invalid.isEmpty {
            throw MCPSelectionToolProvider.invalidOnlySelectionError(invalidPaths: selection.invalid, fallback: "No selection inputs resolved")
        }
        let validatesOrigin: @MainActor @Sendable () async -> Bool = {
            guard await self.hostSelectionOriginIsCurrent(invocation, connection: connection, command: original) else { return false }
            if let lookupLifetime, await !lookupLifetime.isCurrent() { return false }
            return lease.rootsAreCurrent && self.hostFileCommand(connection)?.identity == original.identity
        }
        guard await lease.isCurrent(), await validatesOrigin() else { throw MCPFileToolAuthorityFailure.superseded }
        let next = lookup.logicalizeSelection(selection.selection)
        if op != "preview", op != "get", next != tab.selection {
            _ = try await activation.commitHostSelection(
                next, replacing: tab.selection, in: lease.snapshot, command: original,
                connectionID: connection.connectionID, validatesOrigin: validatesOrigin
            )
        }
        let files = next.selectedPaths.map { path in
            ToolResultDTOs.SelectedFileInfo(path: path, tokens: 0, renderMode: next.slices[path] == nil ? "full" : "slice", ranges: nil, isAuto: false, codemapOrigin: nil, copyPreset: nil)
        } + next.manualCodemapPaths.map { path in
            ToolResultDTOs.SelectedFileInfo(path: path, tokens: 0, renderMode: "codemap", ranges: nil, isAuto: false, codemapOrigin: "manual", copyPreset: nil)
        }
        return try Value(ToolResultDTOs.SelectionReply(
            files: files, totalTokens: nil, status: op == "preview" ? "preview" : "ok",
            invalidPaths: selection.invalid.isEmpty ? nil : selection.invalid, codemapAutoEnabled: next.codemapAutoEnabled
        ))
    }

    private func computeSavedSelection(
        op: String, mode: String, physical: StoredSelection, paths: [String], input: MCPServerViewModel.ManageSelectionInputs,
        slices: [WorkspaceSelectionSliceInput], service: WorkspaceSelectionMutationService, rootScope: WorkspaceLookupRootScope
    ) async -> (selection: StoredSelection, invalid: [String]) {
        switch op {
        case "get": return (physical, [])
        case "clear": return (.init(), [])
        case "set", "preview":
            let result = await service.buildManageSelectionSet(
                paths: paths, slices: slices, sliceErrors: input.sliceErrors, mode: mode, existing: physical, rootScope: rootScope
            )
            return (result.selection, result.invalidPaths)
        case "add":
            let slicePaths = Set(slices.map(\.path))
            let fullPaths = paths.filter { !slicePaths.contains($0) }
            let result = await service.addPaths(existing: physical, paths: fullPaths, rawPaths: fullPaths, mode: mode, rootScope: rootScope)
            if slices.isEmpty { return (result.selection, result.invalidPaths + input.sliceErrors) }
            let sliced = await service.mutateSlices(base: result.selection, entries: slices, mode: .add, rootScope: rootScope)
            return (sliced.selection, result.invalidPaths + sliced.invalidPaths + input.sliceErrors)
        case "remove":
            let result = await service.removePaths(existing: physical, paths: paths, rawPaths: input.paths, mode: mode, rootScope: rootScope)
            return (result.selection, result.invalidPaths)
        case "promote":
            let result = await service.promotePaths(existing: physical, paths: paths, rawPaths: input.paths, rootScope: rootScope)
            return (result.selection, result.invalidPaths)
        case "demote":
            let result = await service.demotePaths(existing: physical, paths: paths, rawPaths: input.paths, rootScope: rootScope)
            return (result.selection, result.invalidPaths)
        default: return (physical, ["Unknown manage_selection operation: \(op)"])
        }
    }

    private func hostSelectionOriginIsCurrent(
        _ invocation: ToolInvocationContext, connection: MCPHostRouteResources.FileReadConnection,
        command: AgentSessionRuntimeStore.Command
    ) async -> Bool {
        guard await ServerNetworkManager.shared.validateToolInvocationContext(
            invocation, expectedWindowID: routeID, expectedServerViewModelIdentity: ObjectIdentifier(route)
        ) else { return false }
        return !Task.isCancelled && hostFileCommand(connection)?.identity == command.identity
    }

    private func applyHostReadSelection(
        _ connection: MCPHostRouteResources.FileReadConnection, snapshot: DomainWorkspaceSnapshot,
        validateResources: MCPFileReadResources.ReadResourceCheck, lookup: WorkspaceLookupContext,
        files: [String], slices additions: [String: [LineRange]]
    ) async throws -> DomainWorkspaceSnapshot? {
        guard let invocation = MCPInvocationContextBridge.current,
              invocation.connectionID == connection.connectionID,
              let original = hostFileCommand(connection), let activation = workspaceActivation
        else {
            throw MCPFileToolAuthorityFailure.superseded
        }
        let purpose = await ServerNetworkManager.shared.runPurpose(for: connection.connectionID)
        guard AutoSliceSelection.shouldApply(purpose: purpose, hasVirtualContext: true) else { return nil }
        let validatesOrigin: @MainActor @Sendable () async -> Bool = {
            guard await self.hostSelectionOriginIsCurrent(invocation, connection: connection, command: original) else { return false }
            do { try await validateResources() }
            catch { return false }
            return self.hostFileCommand(connection)?.identity == original.identity
        }
        guard await validatesOrigin(), let tab = activation.executionTab(in: snapshot, command: original) else {
            throw MCPFileToolAuthorityFailure.superseded
        }
        let selection = lookup.physicalizeSelection(tab.selection)
        var selected = selection.selectedPaths
        var slices = selection.slices
        for path in files {
            let wasSelected = selected.contains(path)
            if !wasSelected { selected.append(path) }
            if let ranges = additions[path] {
                // A partial read must not reduce an already-selected full file to a slice.
                if !wasSelected || slices[path] != nil {
                    slices[path] = SliceRangeMath.normalize((slices[path] ?? []) + ranges)
                }
            } else {
                slices.removeValue(forKey: path)
            }
        }
        let next = lookup.logicalizeSelection(.init(
            selectedPaths: selected, manualCodemapPaths: selection.manualCodemapPaths,
            slices: slices, codemapAutoEnabled: selection.codemapAutoEnabled
        ))
        return try await activation.commitHostSelection(
            next, replacing: tab.selection, in: snapshot, command: original,
            connectionID: connection.connectionID, validatesOrigin: validatesOrigin
        )
    }
}
