import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptFoundation
import RepoPromptMCPServer
import RepoPromptSettingsCore
import RepoPromptWorkspaceContext
import RepoPromptWorkspaceCore

/// Shared file read resources for one independent workspace activation. Each invocation uses
/// its own connection proof and borrows this activation's root retention.
@MainActor
struct MCPFileReadResources {
    static let toolNames: Set<String> = [MCPWindowToolName.getFileTree, MCPWindowToolName.getCodeStructure]
    static let contentToolNames: Set<String> = [MCPWindowToolName.readFile, MCPWindowToolName.search]

    struct ReadResourceCheck: Sendable {
        let validate: @MainActor @Sendable () async throws -> Void

        @MainActor
        func callAsFunction() async throws {
            try await validate()
        }
    }

    struct ContentEffects: Sendable {
        let artifact: MCPAppPhysicalCapabilityAdapters.ReadSelectedAuthorizedGitArtifact
        let selectRead: @MainActor @Sendable (MCPHostRouteResources.FileReadConnection, DomainWorkspaceSnapshot, ReadResourceCheck, WorkspaceLookupContext, ToolResultDTOs.ReadFileReply, String, String) async throws -> DomainWorkspaceSnapshot?
        let selectSearch: @MainActor @Sendable (MCPHostRouteResources.FileReadConnection, DomainWorkspaceSnapshot, ReadResourceCheck, WorkspaceLookupContext, SearchMode, Int, ToolResultDTOs.SearchResultDTO, [String]) async throws -> DomainWorkspaceSnapshot?
    }

    @MainActor
    private final class SelectionReceipt {
        var workspace: DomainWorkspaceSnapshot?
    }

    let workspace: AgentHostWorkspaceResources.Lease
    let settings: GlobalSettingsStore
    var contentEffects: ContentEffects?
    var hostExecutionTab: (@MainActor (DomainWorkspaceSnapshot, MCPHostRouteResources.FileReadConnection) -> ComposeTabState?)?

    var boundToolNames: Set<String> {
        guard contentEffects != nil else { return Self.toolNames }
        return Self.toolNames.union(Self.contentToolNames)
    }
    #if DEBUG
        var beforeReplyValidationForTesting: (@MainActor () async -> Void)?
    #endif

    /// These bindings use the route's coordinator and the shared read tool definitions.
    func binding(named name: String, route: MCPHostRouteResources) -> MCPDomainToolBinding? {
        guard boundToolNames.contains(name) else { return nil }
        guard let definition = MCPDomainReadToolDefinitions.definition(named: name) else {
            preconditionFailure("Missing canonical read definition for \(name)")
        }
        return MCPDomainToolBinding(definition: definition) { args in
            try await invoke(tool: name, route: route, args: args)
        }
    }

    private func invoke(tool: String, route: MCPHostRouteResources, args: [String: Value]) async throws -> Value {
        let readsSelection: Bool
        if tool == MCPWindowToolName.getCodeStructure {
            _ = try MCPFileToolProvider.codeStructureRequest(args)
            readsSelection = args["paths"] == nil
        } else {
            readsSelection = (args["type"]?.stringValue ?? "files") == "files"
                && args["mode"]?.stringValue?.lowercased() == "selected"
                && (args["max_depth"] == nil || args["max_depth"]?.intValue != nil)
        }
        // Defer reporting routing errors until the shared provider has checked parameters.
        let admission = Result {
            let request = try MCPInvocationContextBridge.require(toolName: tool, expectedWindowID: route.identity.routeID)
            return try route.fileReadConnection(metadata: request.metadata, workspaceID: workspace.snapshot.document.workspaceID)
        }
        let provider = MCPDomainReadToolProvider(
            resolveContext: { _, _ in
                let connection = try admission.get()
                if readsSelection { try await route.drainFileReadSelection(for: connection) }
                let handle = try await route.fileReadHandle(for: connection)
                return DomainReadInvocationContext(handle: handle, connectionID: handle.connectionID)
            },
            refreshContext: { handle in
                guard let coordinator = route.coordinator else { throw MCPFileToolAuthorityFailure.unavailable }
                return try await coordinator.refreshReadContext(handle)
            },
            resolveFailure: { tool, args, error in
                guard let failure = error as? MCPFileToolAuthorityFailure else { return nil }
                return try MCPFileToolProvider.authorityFailureValue(toolName: tool, args: args, failure: failure)
            },
            backend: .init { tool, invocation, args, effects in
                try await execute(tool: tool, route: route, connection: admission.get(), invocation: invocation, args: args, effects: effects)
            },
            sideEffects: route.readSideEffectCoordinator
        )
        guard let binding = provider.binding(named: tool) else {
            preconditionFailure("Missing canonical read binding for \(tool)")
        }
        return try await binding(args)
    }

    private func execute(
        tool: String, route: MCPHostRouteResources, connection: MCPHostRouteResources.FileReadConnection,
        invocation: DomainReadInvocationContext, args: [String: Value], effects: MCPDomainReadSideEffectEmitter
    ) async throws -> Value {
        do {
            let context = connection.context
            guard let handle = invocation.handle, handle.context == context,
                  route.fileReadConnectionIsCurrent(connection)
            else { throw MCPFileToolAuthorityFailure.superseded }
            let lease: AgentHostWorkspaceResources.Lease
            let selection: StoredSelection
            let contextRevision: UInt64
            let source = connection.lookupSource
            if let hostExecutionTab {
                lease = try await workspace.capture(workspaceID: context.workspaceID) { hostExecutionTab($0, connection) != nil }
                guard let tab = hostExecutionTab(lease.snapshot, connection), tab.activeAgentSessionID == source.activeAgentSessionID else {
                    throw MCPFileToolAuthorityFailure.superseded
                }
                if connection.savedCarrierSessionID != nil {
                    contextRevision = lease.snapshot.revisions.workingRevision
                } else {
                    guard let canonical = lease.snapshot.contexts.first(where: { $0.metadata.identity == context }) else {
                        throw MCPFileToolAuthorityFailure.unavailable
                    }
                    contextRevision = canonical.revisions.workingRevision
                }
                selection = tab.selection
            } else {
                guard connection.savedCarrierSessionID == nil else { throw MCPFileToolAuthorityFailure.unavailable }
                lease = try await workspace.capture(context: context)
                guard let canonical = lease.snapshot.contexts.first(where: { $0.metadata.identity == context }),
                      source.activeAgentSessionID == canonical.metadata.activeAgentSessionID else {
                    throw MCPFileToolAuthorityFailure.unavailable
                }
                contextRevision = canonical.revisions.workingRevision
                selection = try JSONDecoder().decode(ComposeTabState.self, from: canonical.metadata.documentBytes).selection
            }
            guard handle.workspaceRevision == lease.snapshot.revisions.workingRevision,
                  handle.contextRevision == contextRevision, route.fileReadConnectionIsCurrent(connection)
            else { throw MCPFileToolAuthorityFailure.superseded }
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
            let selectionReceipt = SelectionReceipt()
            let validate: @MainActor @Sendable () async throws -> Void = {
                try Task.checkCancellation()
                // Only the exact receipt of this read's committed selection may advance its
                // baseline. An unrelated concurrent workspace change is still supersession.
                let expectedWorkspace = selectionReceipt.workspace ?? lease.snapshot
                let expectedContext = selectionReceipt.workspace?.contexts.first(where: { $0.metadata.identity == context })?.revisions.workingRevision
                    ?? handle.contextRevision
                let refreshed = try await route.fileReadHandle(for: connection)
                let retained = if selectionReceipt.workspace != nil {
                    await lease.resources.contexts?.workspaceSnapshot(context.workspaceID) == expectedWorkspace
                } else { await lease.isCurrent() }
                guard refreshed.runtimeID == handle.runtimeID, refreshed.runtimeGeneration == handle.runtimeGeneration,
                      refreshed.connectionGeneration == handle.connectionGeneration, refreshed.bindingKind == handle.bindingKind,
                      refreshed.workspaceRevision == expectedWorkspace.revisions.workingRevision,
                      refreshed.contextRevision == expectedContext, retained,
                      await Set(store.rootRefs(scope: .visibleWorkspace)) == Set(roots)
                else { throw MCPFileToolAuthorityFailure.superseded }
                if let lifetime, await !lifetime.isCurrent() {
                    throw MCPFileToolAuthorityFailure.worktreeScopeUnavailable
                }
                // Recheck synchronous revocations after the last actor hop as well.
                guard lease.rootsAreCurrent, route.fileReadConnectionIsCurrent(connection),
                      hostExecutionTab.map({ $0(expectedWorkspace, connection) != nil }) ?? true else {
                    throw MCPFileToolAuthorityFailure.superseded
                }
            }
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
            } else if tool == MCPWindowToolName.getFileTree {
                value = try await executeTree(
                    args: args, store: store, lookup: lookup, selection: selection,
                    isRootless: lease.snapshot.document.metadata.repoPaths.isEmpty, validate: validate
                )
            } else {
                guard let contentEffects else { throw MCPFileToolAuthorityFailure.unavailable }
                let invocationContext = try MCPInvocationContextBridge.require(toolName: tool, expectedWindowID: route.identity.routeID)
                value = try await MCPFileToolProvider.executeContentRead(toolName: tool, args: args, authority: .init(
                    metadata: invocationContext.metadata, lookupContext: lookup, store: store,
                    isRunlessOneShotHint: false, validate: validate,
                    readFile: { input, start, count, lookup in
                        try await MCPServerViewModel.readStoreFile(
                            input: input, startLine1Based: start, lineCount: count, lookupContext: lookup, store: store,
                            workspaceMessage: { await Self.workspaceMessage(store: store, path: $0) }
                        )
                    }, readArtifact: contentEffects.artifact,
                    search: { pattern, mode, regex, insensitive, maxPaths, maxMatches, paths, extensions, excludes, context, wholeWord, countOnly, fuzzy, scope in
                        try await StoreBackedWorkspaceSearch.search(
                            pattern: pattern, mode: mode, isRegex: regex, caseInsensitive: insensitive,
                            maxPaths: maxPaths, maxMatches: maxMatches, paths: paths, includeExtensions: extensions,
                            excludePatterns: excludes, contextLines: context, wholeWord: wholeWord, countOnly: countOnly,
                            fuzzySpaceMatching: fuzzy, rootScope: scope, store: store, workspaceManager: nil
                        )
                    }, selectRead: { reply, path, physical in
                        try await validate()
                        selectionReceipt.workspace = try await contentEffects.selectRead(connection, lease.snapshot, .init(validate: validate), lookup, reply, path, physical)
                    }, selectSearch: { mode, context, reply, paths in
                        try await validate()
                        selectionReceipt.workspace = try await contentEffects.selectSearch(connection, lease.snapshot, .init(validate: validate), lookup, mode, context, reply, paths)
                    }
                ), sideEffects: effects)
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
