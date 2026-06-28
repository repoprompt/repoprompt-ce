import Foundation
import MCP

@MainActor
extension MCPWorktreeToolProvider {
    private struct SessionResolution {
        let sessionID: UUID
        let isRoutedAgentMode: Bool
    }

    func executeMerge(op: Operation, args: [String: Value]) async throws -> ToolResultDTOs.ManageWorktreeReplyDTO {
        let session = try await resolveMergeSession(args: args)
        switch op {
        case .preview:
            return try await executePreview(args: args, session: session)
        case .apply:
            return try await executeApply(args: args, session: session)
        case .status:
            return try executeStatus(args: args, session: session)
        case .continue:
            return try await executeContinue(args: args, session: session)
        case .abort:
            return try await executeAbort(args: args, session: session)
        case .list, .show, .create, .bind, .select, .switch, .unbind:
            throw MCPError.invalidParams("Invalid merge op: \(op.rawValue)")
        }
    }

    private func executePreview(
        args: [String: Value],
        session: SessionResolution
    ) async throws -> ToolResultDTOs.ManageWorktreeReplyDTO {
        let target = try targetSelector(args)
        let includeGraph = parseBool(args["include_graph"]) ?? true
        let graphLimit = graphLimit(args["graph_limit"])
        let preview = try await dependencies.requireTargetWindow().agentModeViewModel.previewWorktreeMerge(
            sessionID: session.sessionID,
            repoRoot: trimmedString(args["repo_root"]),
            target: target,
            contextLines: contextLines(args["context_lines"]),
            detectRenames: parseBool(args["detect_renames"]) ?? false,
            publishArtifacts: parseBool(args["publish_artifacts"]) ?? true,
            graphLimit: graphLimit
        )
        let status = preview.inspection.blockers.isEmpty ? "preview" : "blocked"
        return mergeReply(
            op: "preview",
            status: status,
            sessionID: session.sessionID,
            operationID: preview.operationID,
            inspection: preview.inspection,
            artifacts: preview.artifacts,
            includeGraph: includeGraph,
            graphLimit: graphLimit,
            nextActions: nextActions(for: status, operationID: preview.operationID, target: preview.inspection.target)
        )
    }

    private func executeApply(
        args: [String: Value],
        session: SessionResolution
    ) async throws -> ToolResultDTOs.ManageWorktreeReplyDTO {
        let operationID = try requiredOperationID(args)
        let commitMessage = trimmedString(args["commit_message"])
        let result: GitWorktreeMergeApplyResult
        if session.isRoutedAgentMode {
            guard parseBool(args["confirm_preview"]) != true else {
                throw MCPError.invalidParams("Routed Agent Mode apply must use the worktree merge approval flow, not confirm_preview=true.")
            }
            result = try await dependencies.requireTargetWindow().agentModeViewModel.requestWorktreeMergeReviewAndApply(
                sessionID: session.sessionID,
                operationID: operationID,
                commitMessage: commitMessage
            )
        } else if parseBool(args["confirm_preview"]) == true {
            result = try await dependencies.requireTargetWindow().agentModeViewModel.applyConfirmedWorktreeMerge(
                sessionID: session.sessionID,
                operationID: operationID,
                commitMessage: commitMessage
            )
        } else {
            throw MCPError.invalidParams("apply requires confirm_preview=true for plain MCP callers.")
        }
        return mergeReply(
            op: "apply",
            status: dtoStatus(for: result.status),
            sessionID: session.sessionID,
            operationID: operationID,
            result: result,
            includeGraph: parseBool(args["include_graph"]) ?? true,
            graphLimit: graphLimit(args["graph_limit"])
        )
    }

    private func executeStatus(
        args: [String: Value],
        session: SessionResolution
    ) throws -> ToolResultDTOs.ManageWorktreeReplyDTO {
        let operation = try dependencies.requireTargetWindow().agentModeViewModel.statusWorktreeMerge(
            sessionID: session.sessionID,
            operationID: trimmedString(args["operation_id"])
        )
        return mergeReply(
            op: "status",
            status: dtoStatus(for: operation.status),
            sessionID: session.sessionID,
            operation: operation,
            includeGraph: parseBool(args["include_graph"]) ?? true,
            graphLimit: graphLimit(args["graph_limit"])
        )
    }

    private func executeContinue(
        args: [String: Value],
        session: SessionResolution
    ) async throws -> ToolResultDTOs.ManageWorktreeReplyDTO {
        let operation = try dependencies.requireTargetWindow().agentModeViewModel.statusWorktreeMerge(
            sessionID: session.sessionID,
            operationID: trimmedString(args["operation_id"])
        )
        let confirmed = parseBool(args["confirm"]) ?? session.isRoutedAgentMode
        guard confirmed else {
            throw MCPError.invalidParams("continue requires confirm=true for plain MCP callers.")
        }
        let result = try await dependencies.requireTargetWindow().agentModeViewModel.continueWorktreeMerge(
            sessionID: session.sessionID,
            operationID: operation.id,
            confirmed: true,
            commitMessage: trimmedString(args["commit_message"])
        )
        return mergeReply(
            op: "continue",
            status: dtoStatus(for: result.status),
            sessionID: session.sessionID,
            operationID: operation.id,
            result: result,
            includeGraph: parseBool(args["include_graph"]) ?? true,
            graphLimit: graphLimit(args["graph_limit"])
        )
    }

    private func executeAbort(
        args: [String: Value],
        session: SessionResolution
    ) async throws -> ToolResultDTOs.ManageWorktreeReplyDTO {
        let operation = try dependencies.requireTargetWindow().agentModeViewModel.statusWorktreeMerge(
            sessionID: session.sessionID,
            operationID: trimmedString(args["operation_id"])
        )
        let confirmed = parseBool(args["confirm"]) ?? session.isRoutedAgentMode
        guard confirmed else {
            throw MCPError.invalidParams("abort requires confirm=true for plain MCP callers.")
        }
        let result = try await dependencies.requireTargetWindow().agentModeViewModel.abortWorktreeMerge(
            sessionID: session.sessionID,
            operationID: operation.id,
            confirmed: true
        )
        let status = result.aborted ? "aborted" : "failed"
        return ToolResultDTOs.ManageWorktreeReplyDTO(
            op: "abort",
            merge: .init(
                status: status,
                operationID: operation.id,
                sessionID: session.sessionID.uuidString,
                source: endpointDTO(operation.source),
                target: endpointDTO(result.target),
                targetHeadAfter: result.targetHead,
                visualization: visualizationDTO(
                    operation.visualization,
                    include: parseBool(args["include_graph"]) ?? true,
                    limit: graphLimit(args["graph_limit"]),
                    source: operation.source,
                    target: operation.target,
                    operationSource: "manage_worktree.abort"
                ),
                errorCode: result.aborted ? nil : "no_merge_in_progress",
                error: result.aborted ? nil : result.message,
                nextActions: nextActions(for: status, operationID: operation.id, target: result.target)
            )
        )
    }

    private func resolveMergeSession(args: [String: Value]) async throws -> SessionResolution {
        let metadata = await dependencies.captureRequestMetadata()
        let resolved = try dependencies.resolveTabContextSnapshot(
            metadata,
            MCPWindowToolName.manageWorktree,
            .allowLegacyImplicitRouting
        )
        let isRoutedAgentMode = await (try? dependencies.requireAgentModeConnection(MCPWindowToolName.manageWorktree)) != nil

        if let raw = trimmedString(args["session_id"]) {
            guard let uuid = UUID(uuidString: raw) else {
                throw MCPError.invalidParams("session_id must be a UUID. Received: \(raw)")
            }
            if isRoutedAgentMode,
               let routedSessionID = resolved.snapshot.activeAgentSessionID,
               routedSessionID != uuid
            {
                throw MCPError.invalidParams("session_id must match the routed Agent Mode session.")
            }
            return SessionResolution(sessionID: uuid, isRoutedAgentMode: isRoutedAgentMode)
        }

        guard isRoutedAgentMode else {
            throw MCPError.invalidParams("session_id is required for plain MCP callers.")
        }
        guard let sessionID = resolved.snapshot.activeAgentSessionID else {
            throw MCPError.invalidParams("session_id is required because current MCP routing does not resolve an active Agent session.")
        }
        return SessionResolution(sessionID: sessionID, isRoutedAgentMode: true)
    }

    private func mergeReply(
        op: String,
        status: String,
        sessionID: UUID,
        operationID: String,
        inspection: GitWorktreeMergeInspection,
        artifacts: GitWorktreeMergePreviewArtifacts?,
        includeGraph: Bool,
        graphLimit: Int,
        nextActions: [String]
    ) -> ToolResultDTOs.ManageWorktreeReplyDTO {
        ToolResultDTOs.ManageWorktreeReplyDTO(
            op: op,
            merge: .init(
                status: status,
                operationID: operationID,
                sessionID: sessionID.uuidString,
                source: endpointDTO(inspection.source),
                target: endpointDTO(inspection.target),
                mergeBase: inspection.mergeBase,
                sourceHead: inspection.sourceHead,
                targetHeadBefore: inspection.targetHead,
                visualization: visualizationDTO(
                    inspection.visualization,
                    include: includeGraph,
                    limit: graphLimit,
                    source: inspection.source,
                    target: inspection.target,
                    operationSource: "manage_worktree.\(op)"
                ),
                preflight: preflightDTO(inspection),
                summary: summaryDTO(inspection.summary),
                artifacts: artifactsDTO(artifacts),
                nextActions: nextActions
            )
        )
    }

    private func mergeReply(
        op: String,
        status: String,
        sessionID: UUID,
        operation: AgentSessionWorktreeMergeOperation,
        includeGraph: Bool,
        graphLimit: Int
    ) -> ToolResultDTOs.ManageWorktreeReplyDTO {
        ToolResultDTOs.ManageWorktreeReplyDTO(
            op: op,
            merge: .init(
                status: status,
                operationID: operation.id,
                sessionID: sessionID.uuidString,
                source: endpointDTO(operation.source),
                target: endpointDTO(operation.target),
                mergeBase: operation.mergeBase,
                sourceHead: operation.sourceHead,
                targetHeadBefore: operation.targetHeadBefore,
                mergeCommit: operation.resultCommit,
                visualization: visualizationDTO(
                    operation.visualization,
                    include: includeGraph,
                    limit: graphLimit,
                    source: operation.source,
                    target: operation.target,
                    operationSource: "manage_worktree.\(op)"
                ),
                summary: operation.summary.map(summaryDTO),
                artifacts: artifactsDTO(operation.previewArtifacts),
                conflictFiles: operation.conflictFiles.isEmpty ? nil : operation.conflictFiles,
                staleReason: operation.status == .stale ? operation.lastError : nil,
                errorCode: operation.status == .failed ? "git_merge_failed" : nil,
                error: operation.status == .failed ? operation.lastError : nil,
                postMerge: operation.status == .completed ? "keep" : nil,
                sourceWorktreeStatus: operation.status == .completed ? "redundant" : nil,
                nextActions: nextActions(for: dtoStatus(for: operation.status), operationID: operation.id, target: operation.target)
            )
        )
    }

    private func mergeReply(
        op: String,
        status: String,
        sessionID: UUID,
        operationID: String,
        result: GitWorktreeMergeApplyResult,
        includeGraph: Bool,
        graphLimit: Int
    ) -> ToolResultDTOs.ManageWorktreeReplyDTO {
        ToolResultDTOs.ManageWorktreeReplyDTO(
            op: op,
            merge: .init(
                status: status,
                operationID: operationID,
                sessionID: sessionID.uuidString,
                source: endpointDTO(result.source),
                target: endpointDTO(result.target),
                sourceHead: result.sourceHead,
                targetHeadBefore: result.targetHeadBefore,
                targetHeadAfter: result.targetHeadAfter,
                mergeCommit: result.mergeCommit,
                visualization: visualizationDTO(
                    nil,
                    include: includeGraph,
                    limit: graphLimit,
                    source: result.source,
                    target: result.target,
                    operationSource: "manage_worktree.\(op)"
                ),
                conflictFiles: result.conflictFiles.isEmpty ? nil : result.conflictFiles,
                staleReason: result.staleReason,
                errorCode: result.status == .failed ? "git_merge_failed" : nil,
                error: result.errorMessage,
                postMerge: status == "completed" ? "keep" : nil,
                sourceWorktreeStatus: status == "completed" ? "redundant" : nil,
                nextActions: nextActions(for: status, operationID: operationID, target: result.target)
            )
        )
    }

    private func endpointDTO(_ endpoint: GitWorktreeMergeEndpoint) -> ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO.EndpointDTO {
        .init(
            worktreeID: endpoint.worktreeID,
            repoKey: endpoint.repoKey,
            path: endpoint.path,
            name: endpoint.name,
            branch: endpoint.branch,
            head: endpoint.head,
            shortHead: endpoint.shortHead,
            isMain: endpoint.isMain,
            label: endpoint.displayName
        )
    }

    private func preflightDTO(_ inspection: GitWorktreeMergeInspection) -> ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO.PreflightDTO {
        .init(
            blocked: inspection.isBlocked,
            blockers: inspection.blockers.map { .init(code: $0.code.rawValue, message: $0.message, paths: $0.paths) },
            conflictPrediction: .init(
                status: inspection.conflictPrediction.status.rawValue,
                files: inspection.conflictPrediction.files,
                message: inspection.conflictPrediction.message
            )
        )
    }

    private func summaryDTO(_ summary: GitWorktreeMergeSummary) -> ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO.SummaryDTO {
        .init(
            commits: summary.commits,
            files: summary.files,
            insertions: summary.insertions,
            deletions: summary.deletions
        )
    }

    private func artifactsDTO(_ artifacts: GitWorktreeMergePreviewArtifacts?) -> ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO.ArtifactsDTO? {
        artifacts.map {
            .init(
                snapshotID: $0.snapshotID,
                snapshotDirectory: $0.snapshotDirectory,
                manifestPath: $0.manifestPath,
                mapPath: $0.mapPath,
                allPatchPath: $0.allPatchPath,
                sidecarPath: $0.sidecarPath
            )
        }
    }

    private func visualizationDTO(
        _ text: String?,
        include: Bool,
        limit: Int,
        source: GitWorktreeMergeEndpoint,
        target: GitWorktreeMergeEndpoint,
        operationSource: String
    ) -> ToolResultDTOs.ManageWorktreeReplyDTO.MergeDTO.VisualizationDTO? {
        guard include else { return nil }
        let rawLines = (text?.isEmpty == false ? text! : fallbackVisualization(source: source, target: target))
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        let capped = Array(rawLines.prefix(limit))
        return .init(
            requested: true,
            limit: limit,
            text: capped.joined(separator: "\n"),
            lines: capped,
            lineCount: rawLines.count,
            truncated: rawLines.count > capped.count,
            sourceWorktreeID: source.worktreeID,
            targetWorktreeID: target.worktreeID,
            source: operationSource
        )
    }

    private func fallbackVisualization(source: GitWorktreeMergeEndpoint, target: GitWorktreeMergeEndpoint) -> String {
        """
        target \(target.branch ?? target.displayName) \(target.shortHead)  \(target.path)
           \\
            +-- worktree merge
           /
        source \(source.branch ?? source.displayName) \(source.shortHead)  \(source.path)
        """
    }

    private func nextActions(for status: String, operationID: String, target: GitWorktreeMergeEndpoint) -> [String] {
        switch status {
        case "preview":
            [
                "Apply after approval: manage_worktree {\"op\":\"apply\",\"operation_id\":\"\(operationID)\",\"confirm_preview\":true}",
                "Inspect source/target worktrees: manage_worktree {\"op\":\"list\",\"include_graph\":true}",
                "Target cwd for validation after apply: cd \(target.path)"
            ]
        case "blocked":
            [
                "Resolve preflight blockers, then rerun manage_worktree preview.",
                "Inspect worktrees: manage_worktree {\"op\":\"list\",\"include_status\":true}",
                "Target cwd: cd \(target.path)"
            ]
        case "conflicted":
            [
                "Resolve conflicts in target cwd: cd \(target.path)",
                "Continue after resolving: manage_worktree {\"op\":\"continue\",\"operation_id\":\"\(operationID)\",\"confirm\":true}",
                "Abort if needed: manage_worktree {\"op\":\"abort\",\"operation_id\":\"\(operationID)\",\"confirm\":true}"
            ]
        case "stale":
            [
                "Preview is stale and did not mutate the target. Rerun manage_worktree preview.",
                "Inspect target cwd: cd \(target.path) && git status --short"
            ]
        case "awaiting_approval":
            [
                "Awaiting user approval in Agent Mode for operation \(operationID).",
                "Inspect status: manage_worktree {\"op\":\"status\",\"operation_id\":\"\(operationID)\"}"
            ]
        case "applying":
            [
                "Merge is applying; wait and inspect status again.",
                "Inspect status: manage_worktree {\"op\":\"status\",\"operation_id\":\"\(operationID)\"}"
            ]
        case "awaiting_commit":
            [
                "Target merge has no conflicts and is awaiting commit in target cwd: cd \(target.path)",
                "Continue after verifying: manage_worktree {\"op\":\"continue\",\"operation_id\":\"\(operationID)\",\"confirm\":true}"
            ]
        case "aborted":
            [
                "Merge aborted. Inspect target cwd: cd \(target.path) && git status --short",
                "Review remaining worktrees: manage_worktree {\"op\":\"list\",\"include_status\":true}"
            ]
        case "completed":
            [
                "Validate from target cwd: cd \(target.path) && make dev-test",
                "Inspect target status: cd \(target.path) && git status --short",
                "Review non-destructive cleanup candidates: manage_worktree {\"op\":\"list\",\"include_status\":true}"
            ]
        default:
            ["Inspect status: manage_worktree {\"op\":\"status\",\"operation_id\":\"\(operationID)\"}"]
        }
    }

    private func dtoStatus(for status: GitWorktreeMergeApplyStatus) -> String {
        switch status {
        case .completed, .noOp:
            "completed"
        case .conflicted:
            "conflicted"
        case .stale:
            "stale"
        case .failed:
            "failed"
        }
    }

    private func dtoStatus(for status: AgentSessionWorktreeMergeOperation.Status) -> String {
        switch status {
        case .previewed:
            "preview"
        case .awaitingApproval:
            "awaiting_approval"
        case .applying:
            "applying"
        case .conflicted:
            "conflicted"
        case .awaitingCommit:
            "awaiting_commit"
        case .stale:
            "stale"
        case .completed:
            "completed"
        case .failed:
            "failed"
        case .cancelled:
            "cancelled"
        case .aborted:
            "aborted"
        }
    }

    private func targetSelector(_ args: [String: Value]) throws -> String {
        if let worktreeID = trimmedString(args["target_worktree_id"]) {
            return "@id:\(worktreeID)"
        }
        return trimmedString(args["target"]) ?? "@main"
    }

    private func requiredOperationID(_ args: [String: Value]) throws -> String {
        guard let operationID = trimmedString(args["operation_id"]) else {
            throw MCPError.invalidParams("operation_id is required for apply.")
        }
        return operationID
    }

    private func contextLines(_ value: Value?) -> Int {
        max(0, min(value?.intValue ?? 3, 20))
    }

    private func graphLimit(_ value: Value?) -> Int {
        max(1, min(value?.intValue ?? 24, 200))
    }
}
