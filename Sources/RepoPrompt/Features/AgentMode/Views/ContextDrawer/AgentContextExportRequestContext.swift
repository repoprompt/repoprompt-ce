import Combine
import Foundation

struct AgentContextSelectionMutationTarget {
    let identity: WorkspaceSelectionIdentity
    let expectedSelection: StoredSelection
}

@MainActor
struct AgentContextExportViewContext {
    typealias LookupContextProvider = @MainActor (
        AgentContextExportSource,
        WorkspaceFileContextStore
    ) async -> WorkspaceLookupContext
    typealias CompleteGitDiffResolver = (
        _ rootPath: String,
        _ compareIntent: ReviewGitCompareIntent
    ) async -> String?

    let promptManager: PromptViewModel
    let selectionCoordinator: WorkspaceSelectionCoordinator?
    let currentTabID: UUID?
    let activeAgentSessionID: UUID?
    let worktreeBindingsProvider: (@MainActor (UUID, UUID?) -> [AgentSessionWorktreeBinding])?
    private let lookupContextProvider: LookupContextProvider
    private let completeGitDiffResolver: CompleteGitDiffResolver

    init(
        promptManager: PromptViewModel,
        selectionCoordinator: WorkspaceSelectionCoordinator?,
        currentTabID: UUID?,
        activeAgentSessionID: UUID?,
        worktreeBindingsProvider: (@MainActor (UUID, UUID?) -> [AgentSessionWorktreeBinding])?,
        lookupContextProvider: @escaping LookupContextProvider = { source, store in
            await AgentContextExportResolver.lookupContext(source: source, store: store)
        },
        completeGitDiffResolver: @escaping CompleteGitDiffResolver = { rootPath, compareIntent in
            await AgentContextExportViewContext.resolveCompleteGitDiff(
                rootPath: rootPath,
                compareIntent: compareIntent
            )
        }
    ) {
        self.promptManager = promptManager
        self.selectionCoordinator = selectionCoordinator
        self.currentTabID = currentTabID
        self.activeAgentSessionID = activeAgentSessionID
        self.worktreeBindingsProvider = worktreeBindingsProvider
        self.lookupContextProvider = lookupContextProvider
        self.completeGitDiffResolver = completeGitDiffResolver
    }

    var selectionSummary: AgentContextSelectionSummary {
        AgentContextExportResolver.selectionSummary(
            for: makeExportSource(flushPendingUI: false).selection
        )
    }

    var selectionChangesPublisher: AnyPublisher<WorkspaceSelectionCoordinator.Change, Never> {
        selectionCoordinator?.changes
            ?? Empty<WorkspaceSelectionCoordinator.Change, Never>(completeImmediately: false).eraseToAnyPublisher()
    }

    var modelRequestIdentity: AgentSelectedFilesModelIdentity {
        makeModelRequest(flushPendingUI: false).identity
    }

    func makeModelRequest(flushPendingUI: Bool = true) -> AgentSelectedFilesModelRequest {
        let source = makeExportSource(flushPendingUI: flushPendingUI)
        let cfg = promptManager.resolvePromptContext()
        let filePathDisplay = promptManager.filePathDisplayOption
        return AgentSelectedFilesModelRequest(
            identity: AgentSelectedFilesModelIdentity(
                exportContextIdentity: source.exportContextIdentity,
                filePathDisplay: filePathDisplay,
                codeMapUsage: cfg.codeMapUsage
            ),
            source: source,
            store: promptManager.workspaceFileContextStore,
            filePathDisplay: filePathDisplay,
            codeMapUsage: cfg.codeMapUsage,
            entryMetricsSnapshot: AgentSelectedFilesRequestMetricsSnapshotResolver.activeTokenMetricsSnapshot(
                source: source,
                promptManager: promptManager,
                codeMapUsage: cfg.codeMapUsage,
                filePathDisplay: filePathDisplay
            )
        )
    }

    func makeExportSource(flushPendingUI: Bool = true) -> AgentContextExportSource {
        let activeComposeTabID = promptManager.activeComposeTabID
        let requestedTabID = currentTabID ?? activeComposeTabID
        let selectionSnapshot = requestedTabID.flatMap {
            selectionCoordinator?.selectionSnapshot(for: $0, flushPendingUIIfActive: flushPendingUI)
        }
        return AgentContextExportSourceBuilder.makeSource(
            AgentContextExportSourceBuildRequest(
                requestedTabID: requestedTabID,
                activeComposeTabID: activeComposeTabID,
                activePromptText: promptManager.promptText,
                selectionSnapshot: selectionSnapshot,
                composeTabs: promptManager.currentComposeTabs,
                explicitActiveAgentSessionID: activeAgentSessionID,
                worktreeBindingsProvider: { sessionID, tabID in
                    worktreeBindingsProvider?(sessionID, tabID) ?? []
                }
            )
        )
    }

    func tabMatchesSelectionChange(_ change: WorkspaceSelectionCoordinator.Change) -> Bool {
        let tabID = currentTabID
            ?? selectionCoordinator?.activeTabID()
            ?? promptManager.activeComposeTabID
        return change.tabID == tabID
    }

    func activeSelectionMutationTarget(
        for source: AgentContextExportSource
    ) -> AgentContextSelectionMutationTarget? {
        guard let selectionCoordinator,
              let sourceTabID = source.tabID,
              let identity = selectionCoordinator.activeSelectionIdentity(),
              identity.tabID == sourceTabID
        else { return nil }
        return AgentContextSelectionMutationTarget(
            identity: identity,
            expectedSelection: selectionCoordinator.activeSelectionSnapshot(flushPendingUI: true).selection
        )
    }

    func persistSelection(
        _ selection: StoredSelection,
        target: AgentContextSelectionMutationTarget
    ) async {
        guard let selectionCoordinator else { return }
        _ = await selectionCoordinator.persistSelection(
            selection,
            for: target.identity,
            source: .runtimeMutation,
            expectedCurrentSelection: target.expectedSelection
        )
    }

    func buildClipboardContent(
        for cfg: PromptContextResolved,
        model: AgentContextExportModel?,
        selectedPromptIDsOverride: [UUID]? = nil
    ) async -> String {
        let source = makeExportSource(flushPendingUI: true)
        let store = promptManager.workspaceFileContextStore
        let filePathDisplay = promptManager.filePathDisplayOption
        let onlyIncludeRootsWithSelectedFiles = promptManager.onlyIncludeRootsWithSelectedFiles
        let showCodeMapMarkers = !promptManager.codeMapsGloballyDisabled
        let includeDatetimeInUserInstructions = promptManager.includeDatetimeInUserInstructions
        let promptSectionsOrder = promptManager.promptSectionsOrder
        let disabledPromptSections = promptManager.disabledPromptSections
        let duplicateUserInstructionsAtTop = promptManager.duplicateUserInstructionsAtTop
        let gitRootPath = promptManager.gitViewModel.selectedRootFolder?.fullPath
        let gitComparisonBase = promptManager.gitViewModel.selectedDiffBranch
        let completeGitDiffProvider = Self.makeCompleteGitDiffProvider(
            inclusion: cfg.gitInclusion,
            rootPath: gitRootPath,
            compareIntent: ReviewGitCompareIntent(base: gitComparisonBase),
            resolver: completeGitDiffResolver
        )
        let meta = promptManager.metaInstructions(
            for: cfg,
            selectedPromptIDsOverride: selectedPromptIDsOverride
        )
        let reviewGitContext = await promptManager.freezePromptGitReviewContext(
            tabID: source.tabID,
            sessionID: source.activeAgentSessionID,
            bindings: source.worktreeBindings,
            base: gitComparisonBase
        )
        let lookupContext: WorkspaceLookupContext = if let model, model.source.exportContextIdentity == source.exportContextIdentity {
            model.lookupContext
        } else {
            await lookupContextProvider(source, store)
        }
        let request = AgentContextClipboardRequest(
            cfg: cfg,
            source: source,
            store: store,
            lookupContext: lookupContext,
            filePathDisplay: filePathDisplay,
            onlyIncludeRootsWithSelectedFiles: onlyIncludeRootsWithSelectedFiles,
            showCodeMapMarkers: showCodeMapMarkers,
            metaInstructions: meta,
            includeDatetimeInUserInstructions: includeDatetimeInUserInstructions,
            promptSectionsOrder: promptSectionsOrder,
            disabledPromptSections: disabledPromptSections,
            duplicateUserInstructionsAtTop: duplicateUserInstructionsAtTop,
            reviewGitContext: reviewGitContext,
            completeGitDiffProvider: completeGitDiffProvider
        )
        return await AgentContextExportResolver.buildClipboardContent(request)
    }

    private static func makeCompleteGitDiffProvider(
        inclusion: GitInclusion,
        rootPath: String?,
        compareIntent: ReviewGitCompareIntent,
        resolver: @escaping CompleteGitDiffResolver
    ) -> () async -> String {
        guard inclusion == .complete else { return { "" } }
        guard let rootPath else {
            return { PromptContextGitDiffPolicy.unavailableCompleteGitDiffMessage }
        }
        return {
            await resolver(rootPath, compareIntent) ?? ""
        }
    }

    private static func resolveCompleteGitDiff(
        rootPath: String,
        compareIntent: ReviewGitCompareIntent
    ) async -> String? {
        guard let resolvedRepo = await VCSService.shared.resolveRepo(
            from: URL(fileURLWithPath: rootPath, isDirectory: true)
        ) else { return nil }
        let target: GitDiffTarget = switch compareIntent {
        case .uncommittedHEAD:
            .uncommitted(base: "HEAD")
        case let .uncommittedMergeBase(symbolicBase):
            .uncommittedMergeBase(base: symbolicBase)
        }
        do {
            let result = try await GitDiffEngine.shared.diffText(
                target: target,
                scope: .all,
                selectedAbsolutePaths: [],
                repoURL: resolvedRepo.rootURL
            )
            return result.text.isEmpty ? nil : result.text
        } catch {
            return nil
        }
    }
}
