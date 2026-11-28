import Foundation
import JSONSchema
import MCP
import Ontology
import RepoPromptDomainRuntime
import RepoPromptFileSystem
import RepoPromptShared
import RepoPromptWorkspaceContext
import RepoPromptWorkspaceCore

enum MCPApplyEditsMissingTargetPolicy {
    static func requiresExistingFile(
        _ input: WorkspaceExactFileInput,
        namespace: WorkspaceExactFileNamespace
    ) -> Bool {
        // Root-qualified replay identities must not become create destinations after their binding disappears.
        switch input {
        case .absolute:
            false
        case .explicitRoot:
            true
        case let .relative(relativePath):
            // A resolved alias names one binding, so losing that binding must not redirect the request into creation.
            switch WorkspaceAliasResolver.resolve(
                userPath: relativePath,
                roots: namespace.clientRoots,
                options: RootAliasOptions(requireRemainder: true)
            ) {
            case .prefixed: true
            case .ambiguous, .bareRoot, .notAliasPrefixed: false
            }
        }
    }
}

@MainActor
final class MCPApplyEditsToolProvider: MCPAppToolProviding {
    let group: MCPAppToolGroup = .applyEdits

    typealias EditSummary = ToolResultDTOs.EditSummary

    struct ExecutionContext {
        let metadata: MCPRequestMetadata
        let workspaceID: UUID?
        let tabID: UUID
        let store: WorkspaceFileContextStore
        let lookup: WorkspaceLookupContext
        let approvalStore: ApplyEditsApprovalStore
        let approvalScope: ApplyEditsApprovalScope?
        var selectionCoordinator: WorkspaceSelectionCoordinator?
        var capturedSelectedPaths: Set<String>?
        var requireCurrent: @Sendable () async throws -> Void = {}
        let selectCreated: (WorkspaceFileRecord?) async -> String?
    }

    private enum Admission {
        case admitted(ExecutionContext)
        case refused(MCPMutationRetryableFailure)
    }

    private let runtime: MCPAppToolBinder
    private typealias Dependencies = (
        context: MCPAppPhysicalCapabilityAdapters.Context,
        selection: MCPAppPhysicalCapabilityAdapters.Selection
    )

    private let dependencies: Dependencies

    init(runtime: MCPAppToolBinder, context: MCPAppPhysicalCapabilityAdapters.Context, selection: MCPAppPhysicalCapabilityAdapters.Selection) {
        self.runtime = runtime
        dependencies = (context: context, selection: selection)
    }

    func buildTools() -> [Tool] {
        [applyEditsTool()]
    }

    private func applyEditsTool() -> Tool {
        runtime.tool(
            name: MCPWindowToolName.applyEdits,
            freshnessPolicy: .providerManaged,
            description: """
            Apply direct file edits. Provide exactly ONE of these three modes:

            **Mode 1: Rewrite** - Replace entire file content
            `{"path": "file.swift", "rewrite": "new content...", "on_missing": "create"}`

            **Mode 2: Single replacement** - Find and replace text
            `{"path": "file.swift", "search": "oldCode", "replace": "newCode", "all": true}`

            **Mode 3: Multiple edits** - Apply several replacements
            `{"path": "file.swift", "edits": [{"search": "old1", "replace": "new1"}, {"search": "old2", "replace": "new2"}]}`

            Note: Modes are mutually exclusive. Providing more than one will result in an error.
            Existing workspace files use exact, literal-first paths. Reuse the path returned by `read_file`; `<root-alias>//<relative-path>` explicitly selects a root when needed. Approved external read paths are not editable. Missing-file creation accepts contained absolute paths and unqualified relative destinations; explicit `//` paths and resolved display aliases identify existing files only.

            Options: `verbose` (show diff), `on_missing` (for rewrite only: "error" | "create", default: "error")
            Edits are literal. Use real JSON newlines for multi-line search/replace (not `\\n`). If a match fails, the tool may retry internally with escape decoding.
            """,
            annotations: .repoPromptLocalDestructive,
            inputSchema: .object(
                properties: [
                    "path": .string(description: "File path"),
                    "operation_id": .string(description: "Optional caller-stable correlation ID echoed in applied mutation replies; this does not provide deduplication or replay safety"),
                    "rewrite": .string(description: "Replace the entire file content with this string"),
                    "search": .string(description: "Text to find"),
                    "replace": .string(description: "Replacement text"),
                    "all": .boolean(description: "Replace all occurrences (default: false)"),
                    "edits": .array(
                        description: "Multiple edits",
                        items: .object(
                            properties: [
                                "search": .string(description: "Text to find"),
                                "replace": .string(description: "Replacement text"),
                                "all": .boolean(description: "Replace all occurrences (default: false)")
                            ],
                            required: ["search", "replace"]
                        )
                    ),
                    "verbose": .boolean(description: "Include diff preview"),
                    "on_missing": .string(
                        description: "Behavior when the file is missing (only for `rewrite`)",
                        enum: ["error", "create"]
                    )
                ],
                required: ["path"]
            )
        ) { [self] _, args in
            try await Value(executeApplyEdits(args: args))
        }
    }

    static func resolveMutationTargetAfterFreshness(
        _ input: WorkspaceExactFileInput,
        namespace: WorkspaceExactFileNamespace,
        store: WorkspaceFileContextStore,
        timeout: Duration = .seconds(MCPTimeoutPolicy.workspaceFreshnessWaitTimeoutSeconds)
    ) async throws -> WorkspaceExactExistingFileResolution {
        _ = try await store.awaitAppliedIngressForExplicitRequest(
            input,
            namespace: namespace,
            timeout: timeout
        )
        try Task.checkCancellation()
        let resolution = try await WorkspaceFileMutationService(store: store)
            .resolveExactExistingFile(input, namespace: namespace)
        try Task.checkCancellation()
        return resolution
    }

    private func executeApplyEdits(args: [String: Value]) async throws -> EditSummary {
        let dependencies = dependencies
        return try await Self.execute(args: args, resolve: {
            let metadata = await dependencies.context.captureRequestMetadata()
            let (resolved, lookup) = try await dependencies.selection.resolveMutationFileToolContext(metadata, MCPWindowToolName.applyEdits)
            if let failure = MCPMutationRetryableFailure.unresolvedRouteFailure(for: resolved.snapshot) {
                return .refused(failure)
            }
            let store = try dependencies.context.requirePromptVM().workspaceFileContextStore
            let purpose: MCPRunPurpose? = if let connectionID = metadata.connectionID {
                await ServerNetworkManager.shared.runPurpose(for: connectionID)
            } else { nil }
            let tabID = try Self.resolveApplyEditsAgentModeTabID(
                runPurpose: purpose, virtualTabID: resolved.snapshot.tabID, rawTabID: args["_tabID"]?.stringValue,
                availableTabIDs: Set(dependencies.context.workspaceManager?.activeWorkspace?.composeTabs.map(\.id) ?? [])
            )
            let scope = purpose == .agentModeRun ? tabID.map { ApplyEditsApprovalScope(windowID: dependencies.context.windowID, tabID: $0) } : nil
            return .admitted(.init(
                metadata: metadata, workspaceID: resolved.snapshot.workspaceID, tabID: resolved.snapshot.tabID,
                store: store, lookup: lookup, approvalStore: dependencies.context.applyEditsApprovalStore, approvalScope: scope,
                selectionCoordinator: dependencies.context.selectionCoordinator,
                selectCreated: { await dependencies.selection.selectCreatedFile($0, resolved, metadata, lookup) }
            ))
        }, mapFileError: { await dependencies.context.mapFileManagerErrorToMCP($0, MCPWindowToolName.applyEdits, $1) })
    }

    static func executeHost(args: [String: Value], context: ExecutionContext) async throws -> Value {
        try await Value(execute(args: args, resolve: { .admitted(context) }, mapFileError: { error, _ in
            if case let .fileSystemServiceNotFoundWithContext(message) = error { return MCPError.invalidParams(message) }
            return MCPError.invalidParams(error.localizedDescription)
        }))
    }

    private static func execute(
        args: [String: Value], resolve: () async throws -> Admission,
        mapFileError: (FileManagerError, String?) async -> MCPError
    ) async throws -> EditSummary {
        var requestPath: String? = nil
        do {
            let request = try EditFlowPerf.measure(EditFlowPerf.Stage.ApplyEdits.requestBuild) {
                try ApplyEditsRequestBuilder().buildFromNormalizedPayload(args)
            }
            requestPath = request.path
            let suppliedOperationID = args["operation_id"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let operationID = suppliedOperationID.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
            let context: ExecutionContext
            switch try await resolve() {
            case let .admitted(value): context = value
            case let .refused(failure): return retryableFailureSummary(request: request, failure: failure)
            }
            #if DEBUG
                let metadata = context.metadata
            #endif
            let lookupContext = context.lookup
            let store = context.store
            try await context.requireCurrent()
            if let failure = await MCPMutationRetryableFailure.mutationScopeFailure(for: lookupContext, store: store) {
                return Self.retryableFailureSummary(request: request, failure: failure)
            }
            let exactInput: WorkspaceExactFileInput
            do {
                exactInput = try WorkspaceExactFileInput.parse(request.path)
            } catch let issue as PathResolutionIssue {
                throw MCPError.invalidParams(PathResolutionIssueRenderer.message(for: issue))
            }
            let roots = await store.rootRefs(scope: lookupContext.rootScope)
            let namespace = lookupContext.exactFileNamespace(storeRoots: roots)
            let resolution: WorkspaceExactExistingFileResolution
            do {
                resolution = try await Self.resolveMutationTargetAfterFreshness(
                    exactInput,
                    namespace: namespace,
                    store: store
                )
            } catch is WorkspaceAppliedIngressWaitError {
                return Self.retryableFailureSummary(
                    request: request,
                    failure: .workspaceFreshnessUnavailable()
                )
            }
            let effectivePath: String
            let displayPath: String
            let target: WorkspaceFileEditHost.Target
            switch resolution {
            case let .matched(match):
                effectivePath = match.file.standardizedFullPath
                displayPath = match.canonicalPath
                target = .existing(match.file)
            case let .issue(issue):
                throw MCPError.invalidParams(PathResolutionIssueRenderer.message(for: issue))
            case .directory:
                throw MCPError.invalidParams("'\(request.path)' is a folder; apply_edits requires a file path.")
            case .claimedMissing, .noCandidate:
                if MCPApplyEditsMissingTargetPolicy.requiresExistingFile(exactInput, namespace: namespace) {
                    throw MCPError.invalidParams(
                        "File '\(request.path)' does not exist. Explicit root and resolved display-alias paths identify existing files only."
                    )
                }
                effectivePath = lookupContext.translateInputPath(request.path)
                displayPath = request.path
                target = .create(path: effectivePath)
            }

            let mutationRootMappings = await lookupContext.domainMutationPhysicalRootMappings(store: store)
            let writeReceipt = WorkspaceFileEditHost.WriteReceipt()
            let host = WorkspaceFileEditHost(
                store: store,
                target: target,
                selectionCoordinator: context.selectionCoordinator,
                lookupRootScope: lookupContext.rootScope,
                capturedSelectedPaths: context.capturedSelectedPaths,
                createPathResolutionPolicy: .canonicalAliasFirst,
                selectCreatedFiles: false,
                mutationRootMappings: mutationRootMappings,
                writeReceipt: writeReceipt
            )
            let service = ApplyEditsService(engine: .default, host: host)

            try await context.requireCurrent()

            #if DEBUG
                let probeRequestIdentity = MCPRequestTimelineContext.current
                    ?? MCPApplyEditsRebaseProbeRecorder.latestApplyEditsRequestIdentity(
                        connectionID: metadata.connectionID
                    )
                MCPApplyEditsRebaseProbeRecorder.recordApplyEditsInvocation(
                    connectionID: metadata.connectionID,
                    workspaceID: context.workspaceID,
                    tabID: context.tabID,
                    physicalPath: effectivePath,
                    requestIdentity: probeRequestIdentity
                )
            #endif

            let approvalScope = context.approvalScope

            var shouldRequireApproval = false
            if let approvalScope {
                let autoEditEnabled = await context.approvalStore.autoEditEnabled(for: approvalScope)
                shouldRequireApproval = !autoEditEnabled
            }

            if shouldRequireApproval, let approvalScope {
                try Task.checkCancellation()
                let previewRequest = ApplyEditsRequest(
                    path: effectivePath,
                    mode: request.mode,
                    verbose: true
                )
                let preview = try await service.preview(previewRequest)
                let previewResult = preview.result
                if previewResult.editsApplied == 0 {
                    return editSummary(from: previewResult, path: displayPath)
                }
                let reviewUnifiedDiff = previewResult.unifiedDiffForToolCard(filePath: displayPath)
                    ?? "No textual diff available for this apply_edits request."

                try await context.requireCurrent()
                let decision = await context.approvalStore.requestReview(
                    scope: approvalScope,
                    path: displayPath,
                    unifiedDiff: reviewUnifiedDiff,
                    timeoutSeconds: MCPTimeoutPolicy.applyEditsApprovalTimeoutSeconds
                )

                switch decision {
                case .accept:
                    try Task.checkCancellation()
                    try await context.requireCurrent()
                    try await EditFlowPerf.measure(
                        EditFlowPerf.Stage.ApplyEdits.hostWrite,
                        EditFlowPerf.Dimensions(fileBytes: previewResult.updatedText.utf8.count, appliedCount: previewResult.editsApplied)
                    ) {
                        try Task.checkCancellation()
                        if preview.exists {
                            guard let originalText = preview.originalText else {
                                throw MCPError.internalError("Existing-file preview did not capture its original content.")
                            }
                            try await host.writeTextIfUnchanged(
                                path: effectivePath,
                                content: previewResult.updatedText,
                                expectedOriginalText: originalText
                            )
                        } else {
                            try await host.writeText(
                                path: effectivePath,
                                content: previewResult.updatedText,
                                overwrite: false
                            )
                        }
                    }
                    let freshness = await postMutationFreshness(
                        userPath: effectivePath,
                        rootScope: lookupContext.rootScope, store: store
                    )
                    let persistedResult = previewResult.withFileMetadata(created: !preview.exists, overwritten: false)
                    let selectionWarning = persistedResult.fileCreated
                        ? await context.selectCreated(writeReceipt.file)
                        : nil
                    #if DEBUG
                        MCPApplyEditsRebaseProbeRecorder.recordApplyEditsOutcome(
                            connectionID: metadata.connectionID,
                            workspaceID: context.workspaceID,
                            tabID: context.tabID,
                            physicalPath: effectivePath,
                            requestIdentity: probeRequestIdentity,
                            editsApplied: persistedResult.editsApplied,
                            outcome: "success"
                        )
                    #endif
                    return editSummary(
                        from: persistedResult,
                        path: displayPath,
                        reviewStatus: "accepted",
                        requiresUserApproval: true,
                        operationID: operationID,
                        freshness: freshness,
                        selectionWarning: selectionWarning
                    )
                case let .reject(reason):
                    return editSummary(
                        from: previewResult,
                        path: displayPath,
                        statusOverride: "failed",
                        noteOverride: "Rejected by user: \(reason)",
                        reviewStatus: "rejected",
                        rejectionReason: reason,
                        requiresUserApproval: true
                    )
                case .timeout:
                    return editSummary(
                        from: previewResult,
                        path: displayPath,
                        statusOverride: "failed",
                        noteOverride: "Timed out waiting for apply_edits review approval",
                        reviewStatus: "timeout",
                        requiresUserApproval: true
                    )
                case let .cancelled(reason):
                    return editSummary(
                        from: previewResult,
                        path: displayPath,
                        statusOverride: "failed",
                        noteOverride: "Apply edits review was cancelled: \(reason)",
                        reviewStatus: "cancelled",
                        rejectionReason: reason,
                        requiresUserApproval: true
                    )
                }
            }

            let effectiveRequest = ApplyEditsRequest(path: effectivePath, mode: request.mode, verbose: request.verbose)
            try Task.checkCancellation()
            try await context.requireCurrent()
            let result = try await service.run(effectiveRequest)
            let selectionWarning = result.fileCreated
                ? await context.selectCreated(writeReceipt.file)
                : nil
            let freshness: String?
            if result.editsApplied > 0 {
                freshness = await postMutationFreshness(
                    userPath: effectivePath,
                    rootScope: lookupContext.rootScope, store: store
                )
            } else {
                freshness = nil
                EditFlowPerf.event(
                    EditFlowPerf.Stage.ApplyEdits.flushDeltas,
                    EditFlowPerf.Dimensions(outcome: "skipped", appliedCount: result.editsApplied)
                )
            }
            #if DEBUG
                MCPApplyEditsRebaseProbeRecorder.recordApplyEditsOutcome(
                    connectionID: metadata.connectionID,
                    workspaceID: context.workspaceID,
                    tabID: context.tabID,
                    physicalPath: effectivePath,
                    requestIdentity: probeRequestIdentity,
                    editsApplied: result.editsApplied,
                    outcome: "success"
                )
            #endif
            return editSummary(
                from: result,
                path: displayPath,
                operationID: result.editsApplied > 0 ? operationID : nil,
                freshness: freshness,
                selectionWarning: selectionWarning
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DomainMutationRefusedBeforeEffects {
            throw error
        } catch let error as FileManagerError {
            throw await mapFileError(error, requestPath)
        } catch let error as ApplyEditsError {
            throw Self.mapApplyEditsError(error)
        } catch let error as MCPError {
            throw error
        } catch {
            throw MCPError.internalError(error.localizedDescription)
        }
    }

    private static func postMutationFreshness(
        userPath: String,
        rootScope: WorkspaceLookupRootScope, store: WorkspaceFileContextStore
    ) async -> String {
        await EditFlowPerf.measure(EditFlowPerf.Stage.ApplyEdits.flushDeltas) {
            do {
                _ = try await store.awaitAppliedIngressForExplicitRequest(
                    userPath: userPath,
                    fallbackScope: rootScope,
                    timeout: .seconds(2)
                )
                return "fresh"
            } catch {
                return "pending"
            }
        }
    }

    private static func retryableFailureSummary(
        request: ApplyEditsRequest,
        failure: MCPMutationRetryableFailure
    ) -> EditSummary {
        EditSummary(
            status: "failed",
            editsRequested: request.editCount,
            editsApplied: 0,
            addedLines: nil,
            deletedLines: nil,
            totalLinesChanged: nil,
            totalChunks: nil,
            results: nil,
            unifiedDiff: nil,
            cardUnifiedDiff: nil,
            note: nil,
            fileCreated: nil,
            fileOverwritten: nil,
            reviewStatus: nil,
            rejectionReason: nil,
            requiresUserApproval: nil,
            errorMessage: failure.errorMessage,
            errorCode: failure.errorCode,
            retryable: failure.retryable,
            retryAfterMilliseconds: failure.retryAfterMilliseconds,
            suggestion: failure.suggestion
        )
    }

    private static func resolveApplyEditsAgentModeTabID(
        runPurpose: MCPRunPurpose?,
        virtualTabID: UUID?,
        rawTabID: String?,
        availableTabIDs: Set<UUID>
    ) throws -> UUID? {
        guard runPurpose == .agentModeRun else { return virtualTabID }

        let normalizedRawTabID = normalizedTabIDArgument(rawTabID)
        if let normalizedRawTabID, UUID(uuidString: normalizedRawTabID) == nil {
            throw MCPError.invalidParams("Invalid _tabID '\(normalizedRawTabID)'. Expected a UUID.")
        }
        let explicitTabID = normalizedRawTabID.flatMap(UUID.init(uuidString:))

        let resolvedTabID = virtualTabID ?? explicitTabID
        guard let resolvedTabID else {
            throw MCPError.invalidParams(
                "RepoPrompt could not route this Agent Mode MCP call to the active run. Retry the tool call once. If it fails again, tell the user the RepoPrompt connection failed and ask them to restart this Agent Mode run."
            )
        }
        let sourceDescription = (virtualTabID != nil && resolvedTabID == virtualTabID)
            ? "bound tab"
            : "_tabID '\(resolvedTabID.uuidString)'"
        guard availableTabIDs.contains(resolvedTabID) else {
            throw MCPError.invalidParams("Tab not found for \(sourceDescription).")
        }
        return resolvedTabID
    }

    private static func normalizedTabIDArgument(_ rawTabID: String?) -> String? {
        let trimmed = rawTabID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func editSummary(
        from result: ApplyEditsResult,
        path: String,
        statusOverride: String? = nil,
        noteOverride: String? = nil,
        reviewStatus: String? = nil,
        rejectionReason: String? = nil,
        requiresUserApproval: Bool? = nil,
        operationID: String? = nil,
        freshness: String? = nil,
        selectionWarning: String? = nil
    ) -> EditSummary {
        let lineStats = result.toolCardLineStats()
        let notes = [noteOverride ?? result.note, selectionWarning].compactMap(\.self)
        return EditSummary(
            status: statusOverride ?? result.status.rawValue,
            editsRequested: result.editsRequested,
            editsApplied: result.editsApplied,
            addedLines: lineStats?.addedLines,
            deletedLines: lineStats?.deletedLines,
            totalLinesChanged: result.stats?.linesChanged,
            totalChunks: result.stats?.chunks,
            results: result.outcomes,
            unifiedDiff: result.unifiedDiff,
            cardUnifiedDiff: result.unifiedDiffForToolCard(filePath: path),
            note: notes.isEmpty ? nil : notes.joined(separator: " "),
            fileCreated: result.fileCreated ? true : nil,
            fileOverwritten: result.fileOverwritten ? true : nil,
            reviewStatus: reviewStatus,
            rejectionReason: rejectionReason,
            requiresUserApproval: requiresUserApproval,
            operationID: operationID,
            mutationState: operationID == nil ? nil : "applied",
            freshness: freshness
        )
    }

    private static func mapApplyEditsError(_ error: ApplyEditsError) -> MCPError {
        switch error {
        case let .invalidParams(message):
            MCPError.invalidParams(message)
        case let .internalError(message):
            MCPError.internalError(message)
        }
    }
}
