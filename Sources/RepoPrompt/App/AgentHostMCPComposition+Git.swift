import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptMCPServer
import RepoPromptSettingsCore
import RepoPromptVCS
import RepoPromptWorkspaceContext
import RepoPromptWorkspaceCore

extension AgentSessionRuntimeHost {
    func executeHostGit(_ args: [String: Value], invocation: ToolInvocationContext) async throws -> Value {
        let connection = try route.fileReadConnection(metadata: invocation.metadata)
        let route = route
        let provider = MCPDomainReadToolProvider(resolveContext: { _, _ in
            let handle = try await route.fileReadHandle(for: connection)
            return .init(handle: handle, connectionID: handle.connectionID)
        }, refreshContext: { handle in
            guard let coordinator = route.coordinator else { throw MCPFileToolAuthorityFailure.unavailable }
            return try await coordinator.refreshReadContext(handle)
        }, backend: .init { [weak self] _, domain, args, effects in
            guard let self else { throw MCPFileToolAuthorityFailure.superseded }
            return try await executeHostGit(args, invocation: invocation, domain: domain, effects: effects)
        }, sideEffects: route.readSideEffectCoordinator)
        guard let binding = provider.binding(named: MCPWindowToolName.git) else { throw MCPFileToolAuthorityFailure.unavailable }
        return try await binding(args)
    }

    private func executeHostGit(
        _ args: [String: Value], invocation: ToolInvocationContext,
        domain: DomainReadInvocationContext, effects: MCPDomainReadSideEffectEmitter
    ) async throws -> Value {
        let origin = try await captureHostFileInvocation(invocation)
        let snapshot = origin.lease.snapshot
        guard let activation = workspaceActivation, let handle = domain.handle,
              handle.context == origin.connection.context, handle.runtimeID == route.domainRuntimeIdentity.runtimeID,
              handle.runtimeGeneration == route.domainRuntimeIdentity.lifecycleGeneration,
              handle.workspaceRevision == snapshot.revisions.workingRevision
        else {
            throw MCPFileToolAuthorityFailure.superseded
        }
        let workspace = try JSONDecoder().decode(WorkspaceModel.self, from: snapshot.document.documentBytes)
        let directory = WorkspaceSessionSidecarMigration.workspaceDirectory(for: workspace, root: route.workspaceStorageDirectory)
        let files = origin.lease.resources.files
        let requireCurrent = origin.requireCurrent
        let identity = WorkspaceSelectionIdentity(workspaceID: workspace.id, tabID: origin.tab.id)
        let config = MCPGitToolProvider.HostExecution(
            workspaceID: workspace.id, workspaceDirectory: directory, repoPaths: workspace.repoPaths,
            tabID: origin.tab.id, selection: origin.tab.selection, lookup: origin.lookup,
            bindingSource: origin.connection.lookupSource, files: files, requireCurrent: requireCurrent,
            ensureGitDataRoot: {
                try await requireCurrent()
                guard !workspace.isSystemWorkspace else { throw MCPFileToolAuthorityFailure.unavailable }
                let path = directory.appendingPathComponent("_git_data", isDirectory: true).path
                if let root = await files.exactRootRef(path: path, kind: .workspaceGitData) { return root }
                _ = try await files.loadRoot(path: path, kind: .workspaceGitData, cancelUnderlyingLoadOnCallerCancellation: true)
                guard let root = await files.exactRootRef(path: path, kind: .workspaceGitData) else {
                    throw MCPFileToolAuthorityFailure.unavailable
                }
                try await requireCurrent()
                return root
            }, commitArtifacts: { candidates in
                try await requireCurrent()
                let merge = WorkspaceGitDiffArtifactSelectionService().mergePrimaryArtifacts(existing: origin.tab.selection, candidates: candidates)
                origin.selectionCommit.snapshot = try await activation.commitHostSelection(
                    merge.selection, replacing: origin.tab.selection, in: snapshot, command: origin.command,
                    connectionID: origin.connection.connectionID, validatesOrigin: {
                        do { try await requireCurrent()
                            return true
                        } catch { return false }
                    }
                )
                origin.selectionCommit.selection = merge.selection
                let revision = (origin.selectionCommit.snapshot ?? snapshot).revisions.workingRevision
                return .init(aliases: merge.newlyAddedArtifacts.compactMap(\.clientAlias), selectionRevision: revision)
            }, advertiseArtifacts: { artifacts, expectedRevision in
                try await requireCurrent()
                guard !artifacts.isEmpty else {
                    activation.gitArtifactAdvertisements.invalidate(identity: identity)
                    return
                }
                let workspaceRevision = (origin.selectionCommit.snapshot ?? snapshot).revisions.workingRevision
                guard expectedRevision.map({ $0 == workspaceRevision }) ?? true,
                      let capability = await Self.hostGitArtifactCapability(for: origin, directory: directory)
                else { throw MCPFileToolAuthorityFailure.superseded }
                try await requireCurrent()
                _ = try activation.gitArtifactAdvertisements.replace(identity: identity, capability: capability, artifacts: artifacts)
            }
        )
        return try await MCPGitToolProvider().executeDomainRead(context: domain, appContext: nil, args: args, sideEffects: effects, host: config)
    }

    func readHostSelectedGitArtifact(
        requested: String, translated: String, start: Int?, count: Int?, lookup: WorkspaceLookupContext
    ) async throws -> ToolResultDTOs.ReadFileReply? {
        let paths = Set([requested, translated].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        let usesAlias = paths.contains { $0 == "_git_data" || $0.hasPrefix("_git_data/") }
        guard usesAlias || paths.contains(where: { $0.hasPrefix("/") && $0.contains("/_git_data/") }) else { return nil }
        let invocation = try MCPInvocationContextBridge.require(toolName: MCPWindowToolName.readFile, expectedWindowID: routeID)
        let origin = try await captureHostFileInvocation(invocation)
        let workspace = try JSONDecoder().decode(WorkspaceModel.self, from: origin.lease.snapshot.document.documentBytes)
        let directory = WorkspaceSessionSidecarMigration.workspaceDirectory(for: workspace, root: route.workspaceStorageDirectory)
        let artifactRoot = directory.appendingPathComponent("_git_data", isDirectory: true).standardizedFileURL.path
        guard usesAlias || paths.contains(where: { StandardizedPath.isDescendant($0, of: artifactRoot) }) else { return nil }
        let denied = MCPError.invalidParams("Cannot read '\(requested)'. Git-data artifacts must already be selected and authorized.")
        guard let capability = await Self.hostGitArtifactCapability(for: origin, directory: directory) else { throw denied }
        let authorization = await SelectedGitDiffArtifactAuthorizationService().authorize(.init(
            physicalSelection: lookup.physicalizeSelection(origin.tab.selection), capability: capability, store: origin.lease.resources.files
        ))
        guard let entry = authorization.entries.first(where: {
            let path = $0.file.standardizedFullPath
            return paths.contains(path) || authorization.displayAliasesByAbsolutePath[path].map(paths.contains) == true
        }), let content = entry.loadedContent,
        let alias = authorization.displayAliasesByAbsolutePath[entry.file.standardizedFullPath]
        else { throw denied }
        let prepared = await WorkspaceInteractiveReadProcessor.prepareOffActor(content)
        do {
            let reply = try await MCPReadFileToolProjection.makeBaseReply(
                preparedContent: prepared, startLine1Based: start, lineCount: count, displayPath: alias
            )
            try await origin.requireCurrent()
            return reply.reply
        } catch WorkspaceInteractiveReadRangeError.limitWithNegativeStart {
            throw MCPError.invalidParams("limit parameter is not allowed with negative start_line. Use start_line=-N to read the last N lines.")
        } catch WorkspaceInteractiveReadRangeError.zeroStart {
            throw MCPError.invalidParams("start_line must be positive (1-based) or negative (tail-like behavior)")
        }
    }

    func hostGitArtifactCapability(for origin: HostFileInvocation) async throws -> SelectedGitArtifactCapability? {
        let workspace = try JSONDecoder().decode(WorkspaceModel.self, from: origin.lease.snapshot.document.documentBytes)
        let directory = WorkspaceSessionSidecarMigration.workspaceDirectory(for: workspace, root: route.workspaceStorageDirectory)
        return await Self.hostGitArtifactCapability(for: origin, directory: directory)
    }

    private static func hostGitArtifactCapability(for origin: HostFileInvocation, directory: URL) async -> SelectedGitArtifactCapability? {
        let snapshot = origin.lease.snapshot
        return await FrozenPromptGitReviewContext.make(
            workspaceID: snapshot.document.workspaceID, workspaceDirectoryPath: directory.path,
            workspaceRootPaths: snapshot.document.metadata.repoPaths, tabID: origin.tab.id,
            sessionID: origin.command.identity.sessionID, bindings: origin.connection.lookupSource.worktreeBindings,
            base: "HEAD", store: origin.lease.resources.files
        ).artifactCapability
    }
}
