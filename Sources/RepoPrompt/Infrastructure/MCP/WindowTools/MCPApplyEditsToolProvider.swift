import Foundation
import JSONSchema
import MCP
import Ontology
import RepoPromptShared

@MainActor
final class MCPApplyEditsToolProvider: MCPWindowToolProviding {
    let group: MCPWindowToolGroup = .applyEdits

    private typealias EditSummary = ToolResultDTOs.EditSummary

    private let runtime: MCPWindowToolRuntime
    private let dependencies: MCPWindowToolDependencies

    init(runtime: MCPWindowToolRuntime, dependencies: MCPWindowToolDependencies) {
        self.runtime = runtime
        self.dependencies = dependencies
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

            Options: `verbose` (show diff), `on_missing` (for rewrite only: "error" | "create", default: "error")
            Edits are literal. Use real JSON newlines for multi-line search/replace (not `\\n`). If a match fails, the tool may retry internally with escape decoding.
            """,
            annotations: .repoPromptLocalDestructive,
            inputSchema: .object(
                properties: [
                    "path": .string(description: "File path"),
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
            let metadata = await dependencies.captureRequestMetadata()
            let lookupContext = await dependencies.resolveFileToolLookupContext(metadata)
            let effectivePath = lookupContext.translateInputPath(request.path)
            let displayPath = lookupContext.bindingProjection?.projectedLogicalDisplayPath(forPhysicalPath: effectivePath, display: .relative) ?? request.path
            _ = await dependencies.promptVM.workspaceFileContextStore.awaitAppliedIngressForExplicitRequest(
                userPath: effectivePath,
                fallbackScope: lookupContext.rootScope
            )
            if let issue = await dependencies.promptVM.workspaceFileContextStore.exactPathResolutionIssue(for: effectivePath, kind: .file, rootScope: lookupContext.rootScope) {
                throw MCPError.invalidParams(PathResolutionIssueRenderer.message(for: issue))
            }
            let resolvedContext = try dependencies.resolveTabContextSnapshot(
                metadata,
                MCPWindowToolName.applyEdits,
                MCPServerViewModel.TabContextResolutionPolicy.allowLegacyImplicitRouting
            )
            let store = await MainActor.run { dependencies.promptVM.workspaceFileContextStore }
            let host = WorkspaceFileEditHost(
                store: store,
                selectionCoordinator: dependencies.selectionCoordinator,
                lookupRootScope: lookupContext.rootScope,
                createPathResolutionPolicy: .canonicalAliasFirst,
                selectCreatedFiles: true
            )
            let service = ApplyEditsService(engine: .default, host: host)

            let runPurpose: MCPRunPurpose? = if let connectionID = metadata.connectionID {
                await ServerNetworkManager.shared.runPurpose(for: connectionID)
            } else {
                nil
            }
            let virtualTabID: UUID? = resolvedContext.usesActiveTabCompatibility ? nil : resolvedContext.snapshot.tabID
            let availableTabIDs = await MainActor.run {
                Set(dependencies.workspaceManager?.activeWorkspace?.composeTabs.map(\.id) ?? [])
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
                ApplyEditsApprovalScope(windowID: dependencies.windowID, tabID: tabID)
            } else {
                nil
            }

            var shouldRequireApproval = false
            if let approvalScope {
                let autoEditEnabled = await dependencies.applyEditsApprovalStore.autoEditEnabled(for: approvalScope)
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

                let decision = await dependencies.applyEditsApprovalStore.requestReview(
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
                        try await host.writeText(
                            path: effectivePath,
                            content: previewResult.updatedText,
                            overwrite: preview.exists
                        )
                    }
                    await EditFlowPerf.measure(EditFlowPerf.Stage.ApplyEdits.flushDeltas) {
                        _ = await dependencies.promptVM.workspaceFileContextStore.awaitAppliedIngressForExplicitRequest(
                            userPath: effectivePath,
                            fallbackScope: lookupContext.rootScope
                        )
                    }
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
                        requiresUserApproval: true
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
            if result.editsApplied > 0 {
                await EditFlowPerf.measure(EditFlowPerf.Stage.ApplyEdits.flushDeltas) {
                    _ = await dependencies.promptVM.workspaceFileContextStore.awaitAppliedIngressForExplicitRequest(
                        userPath: effectivePath,
                        fallbackScope: lookupContext.rootScope
                    )
                }
            } else {
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
            return editSummary(from: result, path: displayPath)
        } catch let error as FileManagerError {
            throw await dependencies.mapFileManagerErrorToMCP(error, MCPWindowToolName.applyEdits, requestPath)
        } catch let error as ApplyEditsError {
            throw Self.mapApplyEditsError(error)
        } catch let error as MCPError {
            throw error
        } catch {
            throw MCPError.internalError(error.localizedDescription)
        }
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
        requiresUserApproval: Bool? = nil
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
            requiresUserApproval: requiresUserApproval
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
