import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptFoundation
import RepoPromptMCPServer
import RepoPromptSettingsCore
import RepoPromptWorkspaceContext
import RepoPromptWorkspaceCore

/// Explicit resources for one independent route/context. This is not a workspace authority:
/// all bytes, revisions, root lifetimes and binding projections come from existing owners.
@MainActor
struct MCPFileReadResources {
    static let toolNames: Set<String> = [MCPWindowToolName.getFileTree, MCPWindowToolName.getCodeStructure]

    let context: DomainContextIdentity
    let workspace: AgentHostWorkspaceResources.Lease
    let settings: GlobalSettingsStore
    let lookupSource: @MainActor () throws -> AgentWorkspaceLookupContextSource
    #if DEBUG
        var beforeReplyValidationForTesting: (@MainActor () async -> Void)?
    #endif

    /// These bindings use the route's coordinator and the shared read tool definitions.
    func binding(named name: String, route: MCPHostRouteResources) -> MCPDomainToolBinding? {
        guard Self.toolNames.contains(name) else { return nil }
        let provider = MCPDomainReadToolProvider(
            resolveContext: { tool, _ in
                let request = try MCPInvocationContextBridge.require(toolName: tool, expectedWindowID: route.identity.routeID)
                return try await DomainReadInvocationContext(
                    handle: route.fileReadHandle(metadata: request.metadata, context: context), connectionID: request.connectionID
                )
            },
            refreshContext: { handle in
                guard let coordinator = route.coordinator else { throw MCPFileToolAuthorityFailure.unavailable }
                return try await coordinator.refreshReadContext(handle)
            },
            resolveFailure: { tool, args, error in
                guard let failure = error as? MCPFileToolAuthorityFailure else { return nil }
                return try MCPFileToolProvider.authorityFailureValue(toolName: tool, args: args, failure: failure)
            },
            backend: .init { tool, invocation, args, _ in try await execute(tool: tool, route: route, invocation: invocation, args: args) },
            sideEffects: route.readSideEffectCoordinator
        )
        guard let binding = provider.binding(named: name) else {
            preconditionFailure("Missing canonical read definition for \(name)")
        }
        return MCPDomainToolBinding(definition: binding.definition) { args in
            // Match the physical tool's finite prerequisite and parameter precedence. Drain before
            // handle capture; the shared provider then drains its own high-water and refreshes it.
            let readsSelection: Bool
            if name == MCPWindowToolName.getCodeStructure {
                _ = try MCPFileToolProvider.codeStructureRequest(args)
                readsSelection = args["paths"] == nil
            } else {
                readsSelection = (args["type"]?.stringValue ?? "files") == "files"
                    && args["mode"]?.stringValue?.lowercased() == "selected"
                    && (args["max_depth"] == nil || args["max_depth"]?.intValue != nil)
            }
            if readsSelection {
                let request = try MCPInvocationContextBridge.require(toolName: name, expectedWindowID: route.identity.routeID)
                try await route.drainFileReadSelection(metadata: request.metadata)
            }
            return try await binding(args)
        }
    }

    func execute(
        tool: String, route: MCPHostRouteResources, invocation: DomainReadInvocationContext, args: [String: Value]
    ) async throws -> Value {
        do {
            guard let handle = invocation.handle, handle.context == context else {
                throw MCPFileToolAuthorityFailure.unavailable
            }
            let request = try MCPInvocationContextBridge.require(
                toolName: tool, expectedWindowID: route.identity.routeID
            )
            let lease = try await workspace.capture(context: context)
            guard let canonical = lease.snapshot.contexts.first(where: { $0.metadata.identity == context }) else {
                throw MCPFileToolAuthorityFailure.unavailable
            }
            guard handle.workspaceRevision == lease.snapshot.revisions.workingRevision,
                  handle.contextRevision == canonical.revisions.workingRevision
            else {
                throw MCPFileToolAuthorityFailure.superseded
            }
            let source = try lookupSource()
            guard source.activeAgentSessionID == canonical.metadata.activeAgentSessionID,
                  let connectionID = request.connectionID,
                  route.runRouteBindings.tabContextByConnectionID[connectionID]?.fileToolAuthoritySourceIdentity == source.authorityIdentity
            else {
                throw MCPFileToolAuthorityFailure.superseded
            }
            let store = lease.resources.files
            let roots = await store.rootRefs(scope: .visibleWorkspace)
            guard Set(roots.map { ($0.fullPath as NSString).standardizingPath })
                == Set(lease.snapshot.document.metadata.repoPaths.map { ($0 as NSString).standardizingPath })
            else {
                throw MCPFileToolAuthorityFailure.mismatchedProjection
            }
            let lookup = try await AgentWorkspaceLookupContextResolver.requiredLookupContext(
                source: source, visibleRoots: roots, store: store
            )
            let lifetime: WorkspaceSessionRootLifetimeSnapshot?
            if let projection = lookup.bindingProjection {
                lifetime = await store.sessionBoundRootScopeValidationSnapshot(
                    lookup.rootScope, expectedPhysicalRoots: projection.physicalRootRefs
                )
                guard lifetime != nil else { throw MCPFileToolAuthorityFailure.worktreeScopeUnavailable }
            } else { lifetime = nil }
            let validate: @MainActor () async throws -> Void = {
                try Task.checkCancellation()
                let refreshed = try await route.fileReadHandle(metadata: request.metadata, context: context)
                guard refreshed.runtimeID == handle.runtimeID, refreshed.runtimeGeneration == handle.runtimeGeneration,
                      refreshed.connectionGeneration == handle.connectionGeneration, refreshed.bindingKind == handle.bindingKind,
                      refreshed.workspaceRevision == handle.workspaceRevision, refreshed.contextRevision == handle.contextRevision,
                      !route.isClosing, try lookupSource() == source,
                      route.runRouteBindings.tabContextByConnectionID[connectionID]?.fileToolAuthoritySourceIdentity == source.authorityIdentity,
                      await lease.isCurrent(),
                      await Set(store.rootRefs(scope: .visibleWorkspace)) == Set(roots)
                else { throw MCPFileToolAuthorityFailure.superseded }
                if let lifetime, await !lifetime.isCurrent() {
                    throw MCPFileToolAuthorityFailure.worktreeScopeUnavailable
                }
                // Recheck synchronous revocations after the last actor hop as well.
                guard lease.rootsAreCurrent, !route.isClosing, try lookupSource() == source else {
                    throw MCPFileToolAuthorityFailure.superseded
                }
            }
            // Selection is decoded from this exact canonical context, never the selected presenter.
            let selection = try JSONDecoder().decode(ComposeTabState.self, from: canonical.metadata.documentBytes).selection
            let value: Value
            if tool == MCPWindowToolName.getCodeStructure {
                let codeMapsDisabled = settings.globalCodeMapsDisabled()
                value = try await MCPFileToolProvider.executeGetCodeStructure(args: args, authority: .init(
                    store: store, lookupContext: lookup, validate: validate,
                    resolveExplicit: { paths, rootScope, limit in
                        try await MCPCodeStructureRead.resolveFiles(
                            paths: paths, store: store, lookupRootScope: rootScope, maximumSeedCount: limit
                        )
                    },
                    resolveSelected: { lookup, limit in
                        try await MCPCodeStructureRead.resolveSelectedFiles(
                            selection: selection, store: store, lookupContext: lookup, maximumSeedCount: limit
                        )
                    },
                    buildReply: { files, request, includeMissing, requestedPaths, lookup in
                        try await MCPCodeStructureRead.buildReply(
                            fromRecords: files, request: request, includePathNotFoundIssue: includeMissing,
                            requestedPaths: requestedPaths, lookupContext: lookup,
                            store: store, codeMapsDisabled: codeMapsDisabled
                        )
                    }
                ))
            } else {
                value = try await executeTree(
                    args: args, store: store, lookup: lookup, selection: selection,
                    isRootless: lease.snapshot.document.metadata.repoPaths.isEmpty, validate: validate
                )
            }
            #if DEBUG
                await beforeReplyValidationForTesting?()
            #endif
            try await validate()
            return value
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as MCPFileToolAuthorityFailure {
            return try MCPFileToolProvider.authorityFailureValue(toolName: tool, args: args, failure: failure)
        } catch is AgentHostWorkspaceResources.Failure {
            return try MCPFileToolProvider.authorityFailureValue(toolName: tool, args: args, failure: .superseded)
        } catch is AgentWorkspaceLookupContextResolutionError {
            return try MCPFileToolProvider.authorityFailureValue(toolName: tool, args: args, failure: .worktreeScopeUnavailable)
        }
    }

    private func executeTree(
        args: [String: Value], store: WorkspaceFileContextStore, lookup: WorkspaceLookupContext,
        selection: StoredSelection, isRootless: Bool, validate: @escaping @MainActor () async throws -> Void
    ) async throws -> Value {
        let display = FilePathDisplay(rawValue: settings.filePathDisplayOptionRaw()) ?? .full
        let markers = !settings.globalCodeMapsDisabled()
        return try await MCPFileToolProvider.executeDomainRead(args: args, tree: .init(
            store: store, lookupContext: lookup, filePathDisplay: display,
            isGenuinelyRootless: isRootless,
            validate: validate, drainSelection: nil,
            build: { mode, depth, path, lookup in
                try await validate()
                return try await Self.build(
                    store: store, selection: selection, display: display, showCodeMapMarkers: markers,
                    mode: mode, maxDepth: depth, startPath: path, lookupContext: lookup
                )
            }
        ))
    }

    /// Shared production builder, also used by the legacy physical adapter. No traversal or
    /// schema is duplicated by the independent route composition.
    static func build(
        store: WorkspaceFileContextStore, selection logicalSelection: StoredSelection,
        display: FilePathDisplay, showCodeMapMarkers: Bool,
        mode: String, maxDepth: Int?, startPath: String?, lookupContext: WorkspaceLookupContext,
        workspaceMessage: (@MainActor (String?) async -> String)? = nil
    ) async throws -> (result: FileTreeResult, rootCount: Int, emptyReason: MCPStoreBackedFileTreeEmptyReason?) {
        let presentationMode: WorkspaceFileTreePresentationMode
        switch mode.lowercased() {
        case "selected": presentationMode = .selected
        case "full": presentationMode = .full
        case "folders": presentationMode = .folders
        case "auto": presentationMode = .auto
        default: throw MCPError.invalidParams("invalid mode: \(mode)")
        }
        let selection = lookupContext.physicalizeSelection(logicalSelection)
        if presentationMode == .selected, selection.isEmptyForSelectedFileTree {
            return (FileTreeResult(tree: "No files are selected.", usedSelectedMarker: false, usedCodeMapMarker: false, wasTruncated: false, note: "Selection is empty"), 0, .selectionEmpty)
        }
        let fileTree = await store.makeCurrentSnapshotFileTreePresentation(
            selection: selection,
            request: WorkspaceFileTreePresentationRequest(
                mode: presentationMode, filePathDisplay: display,
                onlyIncludeRootsWithSelectedFiles: presentationMode == .selected, includeLegend: false,
                showCodeMapMarkers: showCodeMapMarkers, rootScope: lookupContext.rootScope,
                startPath: startPath.map { lookupContext.translateInputPath($0) }, maxDepth: maxDepth
            ), lookupContext: lookupContext, profile: .mcpRead
        )
        let selectedProjectionIsEmpty = presentationMode == .selected && selection.manualCodemapPaths.isEmpty
            && fileTree.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if fileTree.rootCount == 0 || selectedProjectionIsEmpty {
            let hasStartPath = startPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let selectedPathsUnavailable = presentationMode == .selected && !hasStartPath
            let msg: String = if selectedPathsUnavailable {
                "No selected files could be resolved in the loaded workspace."
            } else if hasStartPath {
                if let workspaceMessage { await workspaceMessage(startPath) }
                else { await self.workspaceMessage(store: store, path: startPath) }
            } else { "The resolved workspace has no configured roots." }
            let reason: MCPStoreBackedFileTreeEmptyReason = hasStartPath ? .requestedPathOutsideLoadedRoots : (presentationMode == .selected ? .selectionEmpty : .rootProjectionEmpty)
            let note = selectedPathsUnavailable ? "Selected files are unavailable" : (hasStartPath ? "Requested path is outside the loaded roots" : "No roots configured")
            return (FileTreeResult(tree: msg, usedSelectedMarker: false, usedCodeMapMarker: false, wasTruncated: false, note: note), 0, reason)
        }
        return (FileTreeResult(tree: fileTree.content, usedSelectedMarker: fileTree.content.contains(" *"), usedCodeMapMarker: showCodeMapMarkers && fileTree.content.contains(" +"), wasTruncated: false, note: nil), fileTree.rootCount, nil)
    }

    private static func workspaceMessage(store: WorkspaceFileContextStore, path: String?) async -> String {
        let roots = await store.rootRefs(scope: .visibleWorkspace)
        if roots.isEmpty {
            return "No workspace is currently loaded in this window. Use the 'manage_workspaces' tool with action: 'list' to see available workspaces, then action: 'switch' to load one."
        }
        let rootsList = roots.map { "\($0.name) → \($0.fullPath)" }.joined(separator: "; ")
        if let path, !path.isEmpty {
            let standardized = StandardizedPath.absolute((path as NSString).expandingTildeInPath)
            let underRoot = roots.contains { standardized == $0.standardizedFullPath || StandardizedPath.isDescendant(standardized, of: $0.standardizedFullPath) }
            guard path.hasPrefix("/"), !underRoot else { return "Loaded roots: \(rootsList)" }
            return "The requested path '\(path)' is not inside any loaded folder in this window. Loaded roots: \(rootsList). Use the 'manage_workspaces' tool to switch to a workspace containing this path, or add the folder to the current workspace."
        }
        return "Loaded roots: \(rootsList)"
    }
}
