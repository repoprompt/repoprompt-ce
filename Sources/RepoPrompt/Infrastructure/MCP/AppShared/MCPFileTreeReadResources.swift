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
struct MCPFileTreeReadResources {
    let context: DomainContextIdentity
    let workspace: AgentHostWorkspaceResources.Lease
    let settings: GlobalSettingsStore
    let lookupSource: @MainActor () throws -> AgentWorkspaceLookupContextSource
    #if DEBUG
        var beforeReplyValidationForTesting: (@MainActor () async -> Void)?
    #endif

    /// Only this binding uses the route runtime's coordinator; every other catalog binding keeps
    /// its original physical provider and side-effect queue. Definitions remain single-sourced.
    func binding(route: MCPHostRouteResources) -> MCPDomainToolBinding {
        let provider = MCPDomainReadToolProvider(
            resolveContext: { tool, _ in
                let request = try MCPInvocationContextBridge.require(toolName: tool, expectedWindowID: route.identity.routeID)
                return try await DomainReadInvocationContext(
                    handle: route.fileTreeReadHandle(metadata: request.metadata, context: context), connectionID: request.connectionID
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
            backend: .init { _, invocation, args, _ in try await execute(route: route, invocation: invocation, args: args) },
            sideEffects: route.readSideEffectCoordinator
        )
        guard let binding = provider.binding(named: MCPWindowToolName.getFileTree) else {
            preconditionFailure("The canonical read provider must define get_file_tree")
        }
        return MCPDomainToolBinding(definition: binding.definition) { args in
            // Match the physical tool's finite prerequisite and parameter precedence. Drain before
            // handle capture; the shared provider then drains its own high-water and refreshes it.
            if (args["type"]?.stringValue ?? "files") == "files",
               args["mode"]?.stringValue?.lowercased() == "selected",
               args["max_depth"] == nil || args["max_depth"]?.intValue != nil
            {
                let request = try MCPInvocationContextBridge.require(toolName: MCPWindowToolName.getFileTree, expectedWindowID: route.identity.routeID)
                try await route.drainFileTreeSelection(metadata: request.metadata)
            }
            return try await binding(args)
        }
    }

    func execute(
        route: MCPHostRouteResources, invocation: DomainReadInvocationContext, args: [String: Value]
    ) async throws -> Value {
        do {
            guard let handle = invocation.handle, handle.context == context else {
                throw MCPFileToolAuthorityFailure.unavailable
            }
            let request = try MCPInvocationContextBridge.require(
                toolName: MCPWindowToolName.getFileTree, expectedWindowID: route.identity.routeID
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
                let refreshed = try await route.fileTreeReadHandle(metadata: request.metadata, context: context)
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
            let tab = try JSONDecoder().decode(ComposeTabState.self, from: canonical.metadata.documentBytes)
            let display = FilePathDisplay(rawValue: settings.filePathDisplayOptionRaw()) ?? .full
            let markers = !settings.globalCodeMapsDisabled()
            let value = try await MCPFileToolProvider.executeDomainRead(args: args, tree: .init(
                store: store, lookupContext: lookup, filePathDisplay: display,
                isGenuinelyRootless: lease.snapshot.document.metadata.repoPaths.isEmpty,
                validate: validate, drainSelection: nil,
                build: { mode, depth, path, lookup in
                    try await validate()
                    return try await Self.build(
                        store: store, selection: tab.selection, display: display, showCodeMapMarkers: markers,
                        mode: mode, maxDepth: depth, startPath: path, lookupContext: lookup
                    )
                }
            ))
            #if DEBUG
                await beforeReplyValidationForTesting?()
            #endif
            try await validate()
            return value
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as MCPFileToolAuthorityFailure {
            return try MCPFileToolProvider.authorityFailureValue(toolName: MCPWindowToolName.getFileTree, args: args, failure: failure)
        } catch is AgentHostWorkspaceResources.Failure {
            return try MCPFileToolProvider.authorityFailureValue(toolName: MCPWindowToolName.getFileTree, args: args, failure: .superseded)
        } catch is AgentWorkspaceLookupContextResolutionError {
            return try MCPFileToolProvider.authorityFailureValue(toolName: MCPWindowToolName.getFileTree, args: args, failure: .worktreeScopeUnavailable)
        }
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
