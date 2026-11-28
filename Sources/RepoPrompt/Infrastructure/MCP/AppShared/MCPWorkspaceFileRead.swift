import Foundation
import MCP
import RepoPromptDomainRuntime
import RepoPromptFileSystem
import RepoPromptFoundation
import RepoPromptInstrumentation
import RepoPromptShared
import RepoPromptWorkspaceContext
import RepoPromptWorkspaceCore

/// Workspace-backed read projection for both physical and independent MCP routes.
@MainActor
enum MCPWorkspaceFileRead {
    static func readStoreFile(
        input: WorkspaceExactFileInput, startLine1Based: Int?, lineCount: Int?,
        lookupContext: WorkspaceLookupContext, store: WorkspaceFileContextStore,
        workspaceMessage: (String) async -> String
    ) async throws -> MCPAppFileReadResult {
        try await MCPToolWorkCountDiagnostics.withReadFileInvocation {
            try await readFileBody(
                input: input, startLine1Based: startLine1Based, lineCount: lineCount,
                lookupContext: lookupContext, store: store, workspaceMessage: workspaceMessage
            )
        }
    }

    static func resolveReadFileRequestAfterFreshness(
        _ input: WorkspaceExactFileInput,
        readableService: WorkspaceReadableFileService,
        rootScope: WorkspaceLookupRootScope,
        rootRefs: [WorkspaceRootRef],
        namespace: WorkspaceExactFileNamespace,
        timeout: Duration = MCPTimeoutPolicy.workspaceFreshnessWaitTimeout
    ) async throws -> WorkspaceReadableFileResolution {
        try await readableService.awaitFreshnessForExplicitRequest(
            input,
            namespace: namespace,
            timeout: timeout
        )
        try Task.checkCancellation()
        let resolution = try await EditFlowPerf.measure(EditFlowPerf.Stage.ReadFile.resolveReadableFile) {
            try await readableService.resolveReadFileRequest(
                input,
                rootScope: rootScope,
                rootRefs: rootRefs,
                namespace: namespace
            )
        }
        try Task.checkCancellation()
        return resolution
    }

    private static func readFileBody(
        input: WorkspaceExactFileInput,
        startLine1Based: Int?,
        lineCount: Int?,
        lookupContext: WorkspaceLookupContext,
        store: WorkspaceFileContextStore,
        workspaceMessage: (String) async -> String
    ) async throws -> MCPAppFileReadResult {
        try Task.checkCancellation()
        let readableService = WorkspaceReadableFileService(store: store)
        let roots = await store.rootRefs(scope: lookupContext.rootScope)
        let namespace = lookupContext.exactFileNamespace(storeRoots: roots)
        let requestedPath = input.renderedPath
        let resolution = try await Self.resolveReadFileRequestAfterFreshness(
            input,
            readableService: readableService,
            rootScope: lookupContext.rootScope,
            rootRefs: roots,
            namespace: namespace
        )

        let readableFile: WorkspaceReadableFileHandle
        let displayPath: String
        switch resolution {
        case let .workspace(match):
            readableFile = .workspace(match.file)
            displayPath = match.canonicalPath
        case let .external(file):
            readableFile = .external(file)
            displayPath = file.displayPath
        case let .folder(folderDisplayPath):
            throw MCPError.invalidParams("'\(folderDisplayPath)' is a folder; read_file requires a file path. Use get_file_tree or file_search to find specific files.")
        case let .issue(issue):
            throw MCPError.invalidParams(PathResolutionIssueRenderer.message(for: issue))
        case .noCandidate:
            if readableService.isAlwaysReadableExternalPath(requestedPath) {
                throw MCPError.invalidParams("File not found: '\(readableService.displayPath(forExternalPath: requestedPath))'.")
            }
            let msg = await workspaceMessage(requestedPath)
            throw MCPError.invalidParams("Cannot read '\(requestedPath)'. \(msg)")
        }

        let preparedContent: WorkspaceInteractiveReadPreparedContent
        let cacheHit: Bool
        switch readableFile {
        case let .workspace(file):
            guard let snapshot = try await Self.workspaceContentLoad(store: store, file: file)
            else { throw MCPError.internalError("content unavailable") }
            preparedContent = snapshot.preparedContent
            cacheHit = snapshot.cacheHit
        case let .external(externalFile):
            preparedContent = try await Self.prepareAlwaysReadableExternalFile(
                externalFile,
                readableService: readableService
            )
            cacheHit = false
        }
        try Task.checkCancellation()

        let preparedReply: MCPReadFileToolProjection.PreparedReply
        do {
            preparedReply = try await MCPReadFileToolProjection.makeBaseReply(
                preparedContent: preparedContent,
                startLine1Based: startLine1Based,
                lineCount: lineCount,
                displayPath: displayPath
            )
        } catch WorkspaceInteractiveReadRangeError.limitWithNegativeStart {
            throw MCPError.invalidParams("limit parameter is not allowed with negative start_line. Use start_line=-N to read the last N lines.")
        } catch WorkspaceInteractiveReadRangeError.zeroStart {
            throw MCPError.invalidParams("start_line must be positive (1-based) or negative (tail-like behavior)")
        }

        MCPToolWorkCountDiagnostics.recordReadFileResult(
            returnedBytes: preparedReply.reply.content.utf8.count,
            returnedLines: preparedReply.returnedLineCount,
            cacheHit: cacheHit
        )
        switch readableFile {
        case let .workspace(file):
            return .workspace(reply: preparedReply.reply, absolutePhysicalPath: file.standardizedFullPath)
        case .external:
            return .nonSelecting(reply: preparedReply.reply)
        }
    }

    private static func workspaceContentLoad(
        store: WorkspaceFileContextStore,
        file: WorkspaceFileRecord
    ) async throws -> WorkspaceInteractiveReadSnapshot? {
        EditFlowPerf.lifecycleEvent(EditFlowPerf.Lifecycle.ReadFile.contentLoadBegan)
        do {
            let snapshot = try await EditFlowPerf.measure(
                EditFlowPerf.Stage.ReadFile.workspaceContentLoad,
                operation: { try await store.interactiveReadSnapshot(for: file) }
            )
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.contentLoadEnded,
                EditFlowPerf.Dimensions(
                    outcome: snapshot == nil ? "unavailable" : "returned",
                    cacheHit: snapshot?.cacheHit
                )
            )
            return snapshot
        } catch {
            EditFlowPerf.lifecycleEvent(
                EditFlowPerf.Lifecycle.ReadFile.contentLoadEnded,
                EditFlowPerf.Dimensions(outcome: error is CancellationError ? "cancelled" : "error")
            )
            throw error
        }
    }

    #if DEBUG
        static func workspaceContentLoadForTesting(
            store: WorkspaceFileContextStore,
            file: WorkspaceFileRecord
        ) async throws -> WorkspaceInteractiveReadSnapshot? {
            try await workspaceContentLoad(store: store, file: file)
        }
    #endif

    private nonisolated static func prepareAlwaysReadableExternalFile(
        _ externalFile: WorkspaceExternalReadableFile,
        readableService: WorkspaceReadableFileService
    ) async throws -> WorkspaceInteractiveReadPreparedContent {
        do {
            let full = try await readableService.readAlwaysReadableExternalFile(externalFile)
            return await WorkspaceInteractiveReadProcessor.prepareOffActor(full)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ContentReadSchedulerError {
            throw error
        } catch {
            throw MCPError.invalidParams("Cannot read '\(externalFile.displayPath)': \(error.localizedDescription)")
        }
    }

    #if DEBUG
        nonisolated static func prepareAlwaysReadableExternalFileThroughEnvelopeForTesting(
            _ externalFile: WorkspaceExternalReadableFile,
            readableService: WorkspaceReadableFileService
        ) async throws -> WorkspaceInteractiveReadPreparedContent {
            try await prepareAlwaysReadableExternalFile(externalFile, readableService: readableService)
        }
    #endif
}
