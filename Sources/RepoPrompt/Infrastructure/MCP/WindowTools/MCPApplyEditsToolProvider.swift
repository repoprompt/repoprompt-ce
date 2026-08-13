import Foundation
import JSONSchema
import MCP
import Ontology
import RepoPromptShared

@MainActor
final class MCPApplyEditsToolProvider: MCPAppToolProviding {
    let group: MCPAppToolGroup = .applyEdits

    private typealias EditSummary = ToolResultDTOs.EditSummary

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
            Existing workspace files use exact, literal-first paths. Reuse the path returned by `read_file`; `<root-alias>//<relative-path>` explicitly selects a root when needed. Approved external read paths are not editable. Missing-file creation keeps its separate destination rules and does not accept the explicit `//` form.

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

    private func executeApplyEdits(args: [String: Value]) async throws -> EditSummary {
        var requestPath: String? = nil
        do {
            let request = try EditFlowPerf.measure(EditFlowPerf.Stage.ApplyEdits.requestBuild) {
                try ApplyEditsRequestBuilder().buildFromNormalizedPayload(args)
            }
            requestPath = request.path
            let suppliedOperationID = args["operation_id"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let operationID = suppliedOperationID.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString
            let metadata = await dependencies.context.captureRequestMetadata()
            let (resolvedContext, lookupContext) = try await dependencies.selection.resolveMutationFileToolContext(
                metadata,
                MCPWindowToolName.applyEdits
            )
            if let failure = MCPMutationRetryableFailure.unresolvedRouteFailure(
                for: resolvedContext.snapshot
            ) {
                return Self.retryableFailureSummary(request: request, failure: failure)
            }
            if let failure = await MCPMutationRetryableFailure.mutationScopeFailure(
                for: lookupContext,
                store: dependencies.context.promptVM.workspaceFileContextStore
            ) {
                return Self.retryableFailureSummary(request: request, failure: failure)
            }
            let exactInput: WorkspaceExactFileInput
            do {
                exactInput = try WorkspaceExactFileInput.parse(request.path)
            } catch let issue as PathResolutionIssue {
                throw MCPError.invalidParams(PathResolutionIssueRenderer.message(for: issue))
            }
            let store = await MainActor.run { dependencies.context.promptVM.workspaceFileContextStore }
            let roots = await store.rootRefs(scope: lookupContext.rootScope)
            let namespace = lookupContext.exactFileNamespace(storeRoots: roots)
            let freshnessPath = switch exactInput {
            case let .absolute(path): lookupContext.translateInputPath(path)
            case .explicitRoot, .relative: exactInput.renderedPath
            }
            do {
                _ = try await store.awaitAppliedIngressForExplicitRequest(
                    userPath: freshnessPath,
                    fallbackScope: lookupContext.rootScope,
                    timeout: .seconds(MCPTimeoutPolicy.workspaceFreshnessWaitTimeoutSeconds)
                )
            } catch is WorkspaceAppliedIngressWaitError {
                return Self.retryableFailureSummary(
                    request: request,
                    failure: .workspaceFreshnessUnavailable()
                )
            }

            let mutationService = WorkspaceFileMutationService(store: store)
            let resolution = try await mutationService.resolveExactExistingFile(exactInput, namespace: namespace)
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
                if case .explicitRoot = exactInput {
                    throw MCPError.invalidParams("File '\(request.path)' does not exist. Explicit root-qualified paths identify existing files only.")
                }
                effectivePath = lookupContext.translateInputPath(request.path)
                displayPath = request.path
                target = .create(path: effectivePath)
            }

            let mutationRootMappings = await lookupContext.domainMutationPhysicalRootMappings(store: store)
            let host = WorkspaceFileEditHost(
                store: store,
                target: target,
                selectionCoordinator: dependencies.context.selectionCoordinator,
                lookupRootScope: lookupContext.rootScope,
                createPathResolutionPolicy: .canonicalAliasFirst,
                selectCreatedFiles: true,
                mutationRootMappings: mutationRootMappings
            )
            let service = ApplyEditsService(engine: .default, host: host)

            let runPurpose: MCPRunPurpose? = if let connectionID = metadata.connectionID {
                await ServerNetworkManager.shared.runPurpose(for: connectionID)
            } else {
                nil
            }
            let virtualTabID: UUID? = resolvedContext.snapshot.tabID
            let availableTabIDs = await MainActor.run {
                Set(dependencies.context.workspaceManager?.activeWorkspace?.composeTabs.map(\.id) ?? [])
            }
            let tabID = try Self.resolveApplyEditsAgentModeTabID(
                runPurpose: runPurpose,
                virtualTabID: virtualTabID,
                rawTabID: args["_tabID"]?.stringValue,
                availableTabIDs: availableTabIDs
            )

            #if DEBUG
                let probeRequestIdentity = MCPRequestTimelineContext.current
                    ?? MCPApplyEditsRebaseProbeRecorder.latestApplyEditsRequestIdentity(
                        connectionID: metadata.connectionID
                    )
                MCPApplyEditsRebaseProbeRecorder.recordApplyEditsInvocation(
                    connectionID: metadata.connectionID,
                    workspaceID: resolvedContext.snapshot.workspaceID,
                    tabID: resolvedContext.snapshot.tabID,
                    physicalPath: effectivePath,
                    requestIdentity: probeRequestIdentity
                )
            #endif

            let approvalScope: ApplyEditsApprovalScope? = if runPurpose == .agentModeRun, let tabID {
                ApplyEditsApprovalScope(windowID: dependencies.context.windowID, tabID: tabID)
            } else {
                nil
            }

            var shouldRequireApproval = false
            if let approvalScope {
                let autoEditEnabled = await dependencies.context.applyEditsApprovalStore.autoEditEnabled(for: approvalScope)
                shouldRequireApproval = !autoEditEnabled
            }

            if shouldRequireApproval, let approvalScope {
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

                let decision = await dependencies.context.applyEditsApprovalStore.requestReview(
                    scope: approvalScope,
                    path: displayPath,
                    unifiedDiff: reviewUnifiedDiff,
                    timeoutSeconds: MCPTimeoutPolicy.applyEditsApprovalTimeoutSeconds
                )

                switch decision {
                case .accept:
                    try await EditFlowPerf.measure(
                        EditFlowPerf.Stage.ApplyEdits.hostWrite,
                        EditFlowPerf.Dimensions(fileBytes: previewResult.updatedText.utf8.count, appliedCount: previewResult.editsApplied)
                    ) {
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
                        rootScope: lookupContext.rootScope
                    )
                    let persistedResult = previewResult.withFileMetadata(created: !preview.exists, overwritten: false)
                    #if DEBUG
                        MCPApplyEditsRebaseProbeRecorder.recordApplyEditsOutcome(
                            connectionID: metadata.connectionID,
                            workspaceID: resolvedContext.snapshot.workspaceID,
                            tabID: resolvedContext.snapshot.tabID,
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
                        freshness: freshness
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
            let result = try await service.run(effectiveRequest)
            let freshness: String?
            if result.editsApplied > 0 {
                freshness = await postMutationFreshness(
                    userPath: effectivePath,
                    rootScope: lookupContext.rootScope
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
                    workspaceID: resolvedContext.snapshot.workspaceID,
                    tabID: resolvedContext.snapshot.tabID,
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
                freshness: freshness
            )
        } catch let error as FileManagerError {
            throw await dependencies.context.mapFileManagerErrorToMCP(error, MCPWindowToolName.applyEdits, requestPath)
        } catch let error as ApplyEditsError {
            throw Self.mapApplyEditsError(error)
        } catch let error as MCPError {
            throw error
        } catch {
            throw MCPError.internalError(error.localizedDescription)
        }
    }

    private func postMutationFreshness(
        userPath: String,
        rootScope: WorkspaceLookupRootScope
    ) async -> String {
        await EditFlowPerf.measure(EditFlowPerf.Stage.ApplyEdits.flushDeltas) {
            do {
                _ = try await dependencies.context.promptVM.workspaceFileContextStore.awaitAppliedIngressForExplicitRequest(
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

    private func editSummary(
        from result: ApplyEditsResult,
        path: String,
        statusOverride: String? = nil,
        noteOverride: String? = nil,
        reviewStatus: String? = nil,
        rejectionReason: String? = nil,
        requiresUserApproval: Bool? = nil,
        operationID: String? = nil,
        freshness: String? = nil
    ) -> EditSummary {
        let lineStats = result.toolCardLineStats()
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
            note: noteOverride ?? result.note,
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
