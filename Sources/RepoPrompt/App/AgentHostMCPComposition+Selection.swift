import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptFoundation
import RepoPromptMCPServer
import RepoPromptSettingsCore
import RepoPromptWorkspaceContext
import RepoPromptWorkspaceCore

extension AgentSessionRuntimeHost {
    func makeHostFileReadResources(_ lease: AgentHostWorkspaceResources.Lease) -> MCPFileReadResources {
        .init(workspace: lease, settings: .shared, contentEffects: .init(
            artifact: { [weak self] requested, translated, start, count, _, lookup in
                guard let self else { throw MCPFileToolAuthorityFailure.superseded }
                return try await readHostSelectedGitArtifact(requested: requested, translated: translated, start: start, count: count, lookup: lookup)
            },
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
        args: [String: Value], invocation: ToolInvocationContext
    ) async throws -> Value {
        let op = (args["op"]?.stringValue ?? "get").lowercased()
        let mode = (args["mode"]?.stringValue ?? "full").lowercased()
        guard ["get", "clear", "set", "preview", "add", "remove", "promote", "demote"].contains(op) else {
            throw MCPError.invalidParams("Unsupported op '\(op)' for manage_selection when tab context is active")
        }
        guard ["full", "slices", "codemap_only"].contains(mode) else { throw MCPError.invalidParams("Unknown selection mode") }
        let codeMapsDisabled = GlobalSettingsStore.shared.globalCodeMapsDisabled()
        if codeMapsDisabled, mode == "codemap_only" || op == "demote" {
            throw MCPError.invalidParams(MCPSelectionArguments.codeMapsGloballyDisabledMCPMessage)
        }
        guard let activation = workspaceActivation else { throw MCPFileToolAuthorityFailure.unavailable }
        let origin = try await captureHostFileInvocation(invocation)
        let tab = origin.tab
        let store = origin.lease.resources.files
        let lookup = origin.lookup
        if op != "get" { _ = await store.awaitAppliedIngress(rootScope: lookup.rootScope) }
        try Task.checkCancellation()
        let physical = lookup.physicalizeSelection(tab.selection)
        var input = MCPSelectionArguments.parse(
            rawPaths: args["paths"]?.arrayValue?.compactMap(\.stringValue) ?? [], slicesValue: args["slices"]
        )
        let isArtifact = { (path: String) in path == "_git_data" || path.hasPrefix("_git_data/") }
        let artifacts: MCPManageSelectionArtifactResolution?
        if ["set", "add", "preview", "remove"].contains(op),
           input.paths.contains(where: isArtifact) || input.sliceInputs.contains(where: { isArtifact($0.path) })
        {
            let capability = try await hostGitArtifactCapability(for: origin)
            let resolved = await MCPManageSelectionArtifactResolver(store: store, registry: activation.gitArtifactAdvertisements).resolve(.init(
                paths: input.paths, sliceInputs: input.sliceInputs, use: op == "remove" ? .remove : .insert, mode: mode,
                physicalSelection: physical, identity: .init(workspaceID: origin.command.identity.workspaceID, tabID: tab.id),
                capability: capability
            ))
            artifacts = resolved
            input = .init(paths: resolved.ordinaryPaths, sliceInputs: resolved.ordinarySliceInputs, sliceErrors: input.sliceErrors, hadExplicitSliceSpec: input.hadExplicitSliceSpec)
        } else { artifacts = nil }
        let paths = lookup.translateInputPaths(input.paths)
        let slices = input.sliceInputs.map { WorkspaceSelectionSliceInput(path: lookup.translateInputPath($0.path), ranges: $0.ranges) }
        let selectionService = WorkspaceSelectionMutationService(store: store, codemapsGloballyDisabled: codeMapsDisabled)
        var selection = try await computeHostSelection(
            op: op, mode: mode, physical: physical, paths: paths, input: input, slices: slices,
            service: selectionService, rootScope: lookup.rootScope
        )
        if let artifacts {
            selection.invalid += artifacts.invalidDiagnostics
            if !artifacts.absolutePaths.isEmpty {
                selection.selection = Self.applyHostArtifactSelection(paths: artifacts.absolutePaths, removing: op == "remove", to: selection.selection)
            } else if paths.isEmpty, slices.isEmpty, !artifacts.invalidDiagnostics.isEmpty {
                selection.selection = physical
            }
        }
        if args["strict"]?.boolValue == true, selection.selection == physical, !selection.invalid.isEmpty {
            throw MCPSelectionToolProvider.invalidOnlySelectionError(invalidPaths: selection.invalid, fallback: "No selection inputs resolved")
        }
        let validatesOrigin: @MainActor @Sendable () async -> Bool = {
            if let fence = artifacts?.fence {
                let root = fence.capability.gitDataRoot
                guard await store.exactRootRef(path: root.standardizedFullPath, kind: .workspaceGitData) == root,
                      await SelectedGitDiffArtifactAuthorizationService().visibleRootCheckoutsAreCurrent(capability: fence.capability, store: store),
                      fence.grantSnapshot.map({ activation.gitArtifactAdvertisements.isCurrent($0) }) ?? true
                else { return false }
            }
            do { try await origin.requireCurrent()
                return true
            } catch { return false }
        }
        guard await validatesOrigin() else { throw MCPFileToolAuthorityFailure.superseded }
        let next = lookup.logicalizeSelection(selection.selection)
        if op != "preview", op != "get", next != tab.selection {
            let current = try await origin.currentWorkspace()
            _ = try await activation.commitHostSelection(
                next, replacing: tab.selection, in: current, command: origin.command,
                connectionID: origin.connection.connectionID, validatesOrigin: validatesOrigin
            )
        }
        let files = next.selectedPaths.map { path in
            let ranges = next.slices[path]?.map(ToolResultDTOs.LineRangeDTO.init(range:))
            return ToolResultDTOs.SelectedFileInfo(path: path, tokens: 0, renderMode: ranges == nil ? "full" : "slice", ranges: ranges, isAuto: false, codemapOrigin: nil, copyPreset: nil)
        } + next.manualCodemapPaths.map { path in
            ToolResultDTOs.SelectedFileInfo(path: path, tokens: 0, renderMode: "codemap", ranges: nil, isAuto: false, codemapOrigin: "manual", copyPreset: nil)
        }
        return try Value(ToolResultDTOs.SelectionReply(
            files: files, totalTokens: nil, status: op == "preview" ? "preview" : "ok",
            invalidPaths: selection.invalid.isEmpty ? nil : selection.invalid, codemapAutoEnabled: next.codemapAutoEnabled
        ))
    }

    private static func applyHostArtifactSelection(paths: [String], removing: Bool, to selection: StoredSelection) -> StoredSelection {
        var selected = selection.selectedPaths
        let artifactPaths = Set(paths)
        if removing { selected.removeAll(where: artifactPaths.contains) }
        else { selected.append(contentsOf: paths.filter { !selection.selectedPaths.contains($0) }) }
        return .init(
            selectedPaths: selected, manualCodemapPaths: selection.manualCodemapPaths,
            slices: selection.slices.filter { !artifactPaths.contains($0.key) }, codemapAutoEnabled: selection.codemapAutoEnabled
        )
    }

    private func computeHostSelection(
        op: String, mode: String, physical: StoredSelection, paths: [String], input: MCPSelectionArguments.Inputs,
        slices: [WorkspaceSelectionSliceInput], service: WorkspaceSelectionMutationService, rootScope: WorkspaceLookupRootScope
    ) async throws -> (selection: StoredSelection, invalid: [String]) {
        switch op {
        case "get": return (physical, [])
        case "clear":
            return mode == "codemap_only" ? (.init(selectedPaths: physical.selectedPaths, slices: physical.slices, codemapAutoEnabled: false), []) : (.init(), [])
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
            guard !paths.isEmpty, slices.isEmpty else {
                throw MCPError.invalidParams("promote requires paths and does not support slices")
            }
            let result = await service.promotePaths(existing: physical, paths: paths, rawPaths: input.paths, rootScope: rootScope)
            return (result.selection, result.invalidPaths)
        case "demote":
            guard !paths.isEmpty, slices.isEmpty else {
                throw MCPError.invalidParams("demote requires paths and does not support slices")
            }
            let result = await service.demotePaths(existing: physical, paths: paths, rawPaths: input.paths, rootScope: rootScope)
            return (result.selection, result.invalidPaths)
        default: throw MCPError.invalidParams("Unsupported op '\(op)' for manage_selection when tab context is active")
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
