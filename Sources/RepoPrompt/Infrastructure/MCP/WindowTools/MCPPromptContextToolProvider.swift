import Foundation
import MCP
import RepoPromptDomainRuntime

@MainActor
final class MCPPromptContextToolProvider {
    private typealias Dependencies = (
        execution: MCPAppPhysicalCapabilityAdapters.Execution,
        context: MCPAppPhysicalCapabilityAdapters.Context,
        selection: MCPAppPhysicalCapabilityAdapters.Selection,
        files: MCPAppPhysicalCapabilityAdapters.Files,
        prompt: MCPAppPhysicalCapabilityAdapters.Prompt
    )

    private let dependencies: Dependencies

    init(runtime _: MCPAppToolBinder, execution: MCPAppPhysicalCapabilityAdapters.Execution, context: MCPAppPhysicalCapabilityAdapters.Context, selection: MCPAppPhysicalCapabilityAdapters.Selection, files: MCPAppPhysicalCapabilityAdapters.Files, prompt: MCPAppPhysicalCapabilityAdapters.Prompt) {
        dependencies = (execution: execution, context: context, selection: selection, files: files, prompt: prompt)
    }

    func executeDomainRead(
        toolName: String,
        context _: DomainReadInvocationContext,
        appContext: MCPServerViewModel.DomainReadAppExecutionContext?,
        args: [String: Value]
    ) async throws -> Value {
        switch toolName {
        case MCPWindowToolName.workspaceContext:
            try await executeWorkspaceContext(args: args, appContext: appContext)
        case MCPWindowToolName.prompt:
            try await executePrompt(args: args, appContext: appContext)
        default:
            throw MCPError.invalidParams("Unsupported prompt/context read tool: \(toolName)")
        }
    }

    func executeWorkspaceContext(
        args: [String: Value],
        appContext: MCPServerViewModel.DomainReadAppExecutionContext? = nil
    ) async throws -> Value {
        let operation = MCPPromptContextOperation.parse(
            toolName: MCPWindowToolName.workspaceContext,
            arguments: args
        )
        if operation != .snapshot {
            var forwarded = args
            forwarded["op"] = .string(operation.rawValue)
            switch operation {
            case .export, .listPresets, .selectPreset:
                return try await executePromptBody(
                    operation: operation,
                    args: forwarded,
                    appContext: appContext
                )
            default:
                throw MCPError.invalidParams("Unsupported workspace_context op '\(operation.rawValue)'. Use snapshot, export, list_presets, or select_preset.")
            }
        }
        let includeArr = args["include"]?.arrayValue?.compactMap { $0.stringValue?.lowercased() } ?? ["prompt", "selection", "code", "tokens"]
        let display: FilePathDisplay = ((args["path_display"]?.stringValue ?? "relative").lowercased() == "full") ? .full : .relative
        let overridePreset = try await resolveCopyPresetOverride(args["copy_preset"])
        let metadata: MCPServerViewModel.RequestMetadata
        let lookupContext: WorkspaceLookupContext
        if let appContext {
            metadata = appContext.metadata
            lookupContext = appContext.lookupContext
        } else {
            metadata = await dependencies.context.captureRequestMetadata()
            lookupContext = await dependencies.selection.resolveFileToolLookupContext(metadata)
        }
        guard try await dependencies.files.drainReadFileAutoSelection(metadata, .mirroredSelectionAndMetrics) == .completed else {
            throw CancellationError()
        }
        if includeArr.contains("files") {
            _ = await dependencies.context.promptVM.workspaceFileContextStore.awaitAppliedIngress(rootScope: lookupContext.rootScope)
        }
        let resolvedTabContext: MCPServerViewModel.ResolvedTabContextSnapshot = if let appContext {
            selectionRefreshedContext(appContext.resolvedTabContext)
        } else {
            try await dependencies.context.resolveTabContextSnapshot(
                metadata,
                MCPWindowToolName.workspaceContext
            )
        }
        let dto = try await dependencies.prompt.buildTabWorkspaceContext(
            resolvedTabContext.snapshot,
            Set(includeArr),
            display,
            overridePreset,
            false
        )
        return try Value(dto)
    }

    func executePrompt(
        args: [String: Value],
        appContext: MCPServerViewModel.DomainReadAppExecutionContext? = nil
    ) async throws -> Value {
        let operation = MCPPromptContextOperation.parse(
            toolName: MCPWindowToolName.prompt,
            arguments: args
        )
        return try await executePromptBody(
            operation: operation,
            args: args,
            appContext: appContext
        )
    }

    private func executePromptBody(
        operation: MCPPromptContextOperation,
        args: [String: Value],
        appContext: MCPServerViewModel.DomainReadAppExecutionContext?
    ) async throws -> Value {
        if operation == .listPresets {
            return try Value(ToolResultDTOs.PromptToolEnvelope.forPresetsList(dependencies.prompt.buildCopyPresetsListDTO()))
        }
        let metadata: MCPServerViewModel.RequestMetadata = if let appContext {
            appContext.metadata
        } else {
            await dependencies.context.captureRequestMetadata()
        }
        let resolvedContext: MCPServerViewModel.ResolvedTabContextSnapshot = if operation == .export {
            try await withPromptExportPhase(.promptExportSelectionDrain) {
                guard try await dependencies.files.drainReadFileAutoSelection(metadata, .mirroredSelectionAndMetrics) == .completed else {
                    throw CancellationError()
                }
                return if let appContext {
                    selectionRefreshedContext(appContext.resolvedTabContext)
                } else {
                    try await dependencies.context.resolveTabContextSnapshot(
                        metadata,
                        MCPWindowToolName.prompt
                    )
                }
            }
        } else {
            if let appContext {
                selectionRefreshedContext(appContext.resolvedTabContext)
            } else {
                try await dependencies.context.resolveTabContextSnapshot(
                    metadata,
                    MCPWindowToolName.prompt
                )
            }
        }
        return try await executeTabScopedPrompt(
            operation: operation,
            args: args,
            resolvedContext: resolvedContext
        )
    }

    private func executeTabScopedPrompt(operation: MCPPromptContextOperation, args: [String: Value], resolvedContext: MCPServerViewModel.ResolvedTabContextSnapshot) async throws -> Value {
        let tabContext = resolvedContext.snapshot
        switch operation {
        case .get:
            return try Value(simplePromptReply(tabContext.promptText, op: operation.rawValue))
        case .set:
            guard let text = args["text"]?.stringValue else { throw MCPError.invalidParams("text required for set") }
            try await MCPDomainMutationCommitContext.willCommit()
            try await dependencies.context.updateCurrentTabContext(MCPWindowToolName.prompt) { $0.promptText = text }
            let context = try await dependencies.execution.requireCurrentTabContext(MCPWindowToolName.prompt)
            return try Value(simplePromptReply(context.promptText, op: operation.rawValue))
        case .append:
            guard let text = args["text"]?.stringValue else { throw MCPError.invalidParams("text required for append") }
            try await MCPDomainMutationCommitContext.willCommit()
            try await dependencies.context.updateCurrentTabContext(MCPWindowToolName.prompt) { $0.promptText += text }
            let context = try await dependencies.execution.requireCurrentTabContext(MCPWindowToolName.prompt)
            return try Value(simplePromptReply(context.promptText, op: operation.rawValue))
        case .clear:
            try await MCPDomainMutationCommitContext.willCommit()
            try await dependencies.context.updateCurrentTabContext(MCPWindowToolName.prompt) { $0.promptText = "" }
            return try Value(simplePromptReply("", op: operation.rawValue))
        case .export:
            return try await exportPrompt(args: args, resolvedContext: resolvedContext, tabContext: tabContext)
        case .selectPreset:
            guard tabContext.explicitlyBound, tabContext.runID == nil else {
                throw MCPError.invalidParams("select_preset requires an explicitly bound tab (bind_context or _tabID). It is disabled for run-based bindings; use copy_preset override in workspace_context or export instead.")
            }
            let preset = try await resolveRequiredPreset(args["preset"])
            try await MCPDomainMutationCommitContext.willCommit()
            await MainActor.run { dependencies.context.promptVM.selectCopyPreset(preset.id) }
            return try Value(ToolResultDTOs.PromptToolEnvelope.forSelectPreset(dependencies.prompt.copyPresetDescriptorDTO(preset)))
        case .snapshot, .listPresets, .unknown:
            throw MCPError.invalidParams("Unsupported op '\(operation.rawValue)' for prompt when tab context is active")
        }
    }

    /// Refreshes only the exact canonical selection consumed after the legacy selection queue
    /// drains. Routing, prompt, worktree, and lookup authority remain the invocation snapshot;
    /// this avoids a second heavyweight tab-routing resolution on MainActor.
    private func selectionRefreshedContext(
        _ captured: MCPServerViewModel.ResolvedTabContextSnapshot
    ) -> MCPServerViewModel.ResolvedTabContextSnapshot {
        guard let workspaceID = captured.snapshot.workspaceID,
              let manager = dependencies.context.workspaceManager,
              let tab = manager.composeTab(for: WorkspaceSelectionIdentity(
                  workspaceID: workspaceID,
                  tabID: captured.snapshot.tabID
              ))
        else { return captured }
        let revision = manager.selectionRevisionForMCP(
            workspaceID: workspaceID,
            tabID: tab.id
        )
        guard revision >= captured.snapshot.selectionRevision else { return captured }
        var refreshed = captured
        refreshed.snapshot.selection = tab.selection
        refreshed.snapshot.selectionRevision = revision
        return refreshed
    }

    private func simplePromptReply(_ text: String, op: String) -> ToolResultDTOs.PromptToolEnvelope {
        let lines = text.isEmpty ? 0 : text.components(separatedBy: "\n").count
        return .forPrompt(ToolResultDTOs.PromptReply(prompt: text, lines: lines, copyPresetName: nil, chatPresetName: nil, chatMode: nil, includesFiles: nil, includesFileTree: nil, includesCodemaps: nil, includesGitDiff: nil, includesUserPrompt: nil, includesMetaPrompts: nil, includesStoredPrompts: nil, fileTreeMode: nil, codeMapUsage: nil, gitInclusion: nil, effectiveTokens: nil, fullFilesTokens: nil, codeMapFileCount: nil, codeMapTokens: nil, codeMapFiles: nil), op: op)
    }

    private func activePromptReply(op: String) async throws -> Value {
        let prompt = await dependencies.context.promptVM.promptText
        let lines = prompt.isEmpty ? 0 : prompt.components(separatedBy: "\n").count
        let copyPreset = await dependencies.context.promptVM.currentCopyPreset()
        let chatPreset = await dependencies.context.promptVM.currentChatPreset()
        let resolved = await dependencies.context.promptVM.resolvePromptContext()
        let effectiveTokens = await dependencies.context.promptVM.calculateTokensForChatContext()
        let fullFilesTokens = await dependencies.context.promptVM.tokenCountingViewModel.totalTokenCountFilesOnly
        let includesCodemaps = resolved.codeMapUsage != .none
        let includesGitDiff = resolved.gitInclusion != .none
        let hasStoredPrompts = resolved.storedPromptIds?.isEmpty == false
        let codeMapFileCount = includesCodemaps ? await dependencies.context.promptVM.codeMapFileCount : nil
        let codeMapTokens = includesCodemaps ? await dependencies.context.promptVM.codeMapTokenCount : nil
        let codeMapFiles: [String]? = try await {
            guard includesCodemaps else { return nil }
            let collections = try await dependencies.prompt.selectionCollectionsForCurrentTabContext()
            let roots = await dependencies.context.promptVM.workspaceFileContextStore.rootRefs(scope: .allLoaded)
            let display = dependencies.context.promptVM.filePathDisplayOption
            return collections.codemap.map { entry in
                if display == .full {
                    return entry.file.fullPath
                }
                guard let root = roots.first(where: { $0.id == entry.file.rootID }) else { return entry.file.relativePath }
                return ClientPathFormatter.displayPath(root: root, relativePath: entry.file.standardizedRelativePath, visibleRoots: roots)
            }
        }()
        let envelope = ToolResultDTOs.PromptToolEnvelope.forPrompt(ToolResultDTOs.PromptReply(
            prompt: prompt,
            lines: lines,
            copyPresetName: copyPreset.name,
            chatPresetName: chatPreset.name,
            chatMode: chatPreset.mode.rawValue,
            includesFiles: resolved.includeFiles,
            includesFileTree: resolved.rendersFileTree,
            includesCodemaps: includesCodemaps,
            includesGitDiff: includesGitDiff,
            includesUserPrompt: resolved.includeUserPrompt,
            includesMetaPrompts: resolved.includeMetaPrompts,
            includesStoredPrompts: hasStoredPrompts,
            fileTreeMode: resolved.effectiveFileTreeMode.rawValue,
            codeMapUsage: resolved.codeMapUsage.rawValue,
            gitInclusion: resolved.gitInclusion.rawValue,
            effectiveTokens: effectiveTokens,
            fullFilesTokens: fullFilesTokens,
            codeMapFileCount: codeMapFileCount,
            codeMapTokens: codeMapTokens,
            codeMapFiles: codeMapFiles
        ), op: op)
        return try Value(envelope)
    }

    private func exportPrompt(
        args: [String: Value],
        resolvedContext: MCPServerViewModel.ResolvedTabContextSnapshot,
        tabContext: MCPServerViewModel.TabContextSnapshot?
    ) async throws -> Value {
        guard let rawPath = args["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty else {
            throw MCPError.invalidParams("path required for export")
        }

        let preset = try await withPromptExportPhase(.promptExportPresetResolution) {
            let overridePreset = try await resolveCopyPresetOverride(args["copy_preset"])
            let activePreset = await dependencies.context.promptVM.currentCopyPreset()
            let effectivePreset = overridePreset ?? activePreset
            let cfg = dependencies.context.promptVM.resolvePromptContext(
                effectivePreset,
                custom: dependencies.context.promptVM.workingCopyCustomizations
            )
            return (effectivePreset: effectivePreset, cfg: cfg)
        }

        let text = try await withPromptExportPhase(.promptExportContentAssembly) {
            if let tabContext {
                await dependencies.prompt.buildTabClipboardContent(preset.cfg, tabContext)
            } else {
                await dependencies.context.promptVM.buildClipboard(for: preset.cfg)
            }
            // Clipboard assembly is nonthrowing and app-adapter loss can yield an empty
            // compatibility result, so cancellation is revalidated before authorization.
        }

        let exportMetadata = try await withPromptExportPhase(.promptExportMetadataAssembly) {
            let pathDisplay = dependencies.context.promptVM.filePathDisplayOption
            let rootRefs = await dependencies.context.promptVM.workspaceFileContextStore.rootRefs(scope: .allLoaded)
            let effectiveContext = tabContext.map { MCPServerViewModel.ResolvedTabContextSnapshot(snapshot: $0) } ?? resolvedContext
            let files = try await dependencies.prompt.buildExportSelectedFileInfos(
                effectiveContext,
                preset.cfg,
                tabContext?.selection,
                pathDisplay
            )
            return (
                pathDisplay: pathDisplay,
                rootRefs: rootRefs,
                files: files,
                tokens: TokenCalculationService.estimateTokens(for: text),
                bytes: text.lengthOfBytes(using: .utf8)
            )
        }

        let destination = try await withPromptExportPhase(.promptExportDestinationAuthorization) {
            let metadata = await dependencies.context.captureRequestMetadata()
            let lookupContext = await dependencies.selection.resolveFileToolLookupContext(metadata)
            let mutationRootMappings = await lookupContext.domainMutationPhysicalRootMappings(
                store: dependencies.context.promptVM.workspaceFileContextStore
            )
            return (
                physicalPath: lookupContext.translateInputPath(rawPath),
                mutationRootMappings: mutationRootMappings
            )
        }

        let resolvedPath = try await withPromptExportPhase(.promptExportDurableWrite) {
            await dependencies.prompt.reachExportPhaseHook(.beforeDurableWrite)
            try Task.checkCancellation()
            let path = try await dependencies.prompt.writePromptExportFile(
                destination.physicalPath,
                text,
                destination.mutationRootMappings
            )
            await dependencies.prompt.reachExportPhaseHook(.afterDurableWrite)
            return path
        }

        try await withPromptExportPhase(.promptExportIngressWait) {
            _ = await dependencies.context.promptVM.workspaceFileContextStore.awaitAppliedIngressForExplicitRequest(
                userPath: resolvedPath,
                fallbackScope: .allLoaded
            )
        }

        return try await withPromptExportPhase(.promptExportReplyAssembly) {
            let exportPath = exportMetadata.pathDisplay == .full
                ? resolvedPath
                : MCPWindowWorkspaceToolHelpers.prefixedRelativePath(
                    forPath: resolvedPath,
                    rootRefs: exportMetadata.rootRefs
                )
            let envelope = ToolResultDTOs.PromptToolEnvelope.forExport(ToolResultDTOs.PromptExportReply(
                path: exportPath,
                tokens: exportMetadata.tokens,
                bytes: exportMetadata.bytes,
                files: exportMetadata.files,
                copyPreset: dependencies.prompt.copyPresetDescriptorDTO(preset.effectivePreset)
            ))
            return try Value(envelope)
        }
    }

    private func withPromptExportPhase<T>(
        _ phase: MCPToolExecutionHandlerPhase,
        operation: () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        await MCPToolExecutionHandlerPhaseContext.report(phase)
        do {
            let value = try await operation()
            try Task.checkCancellation()
            await MCPToolExecutionHandlerPhaseContext.report(phase, transition: .completed)
            return value
        } catch {
            await MCPToolExecutionHandlerPhaseContext.report(phase, transition: .completed)
            throw error
        }
    }

    private func resolveCopyPresetOverride(_ value: Value?) async throws -> CopyPreset? {
        guard let selector = dependencies.prompt.parseCopyPresetSelector(value) else { return nil }
        guard let preset = dependencies.prompt.resolveCopyPreset(selector) else { throw MCPError.invalidParams("copy_preset not found") }
        return preset
    }

    private func resolveRequiredPreset(_ value: Value?) async throws -> CopyPreset {
        guard let selector = dependencies.prompt.parseCopyPresetSelector(value) else {
            throw MCPError.invalidParams("preset parameter required for select_preset (UUID, kind, or name)")
        }
        guard let preset = dependencies.prompt.resolveCopyPreset(selector) else { throw MCPError.invalidParams("preset not found") }
        return preset
    }
}
